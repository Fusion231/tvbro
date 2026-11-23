// Run in a browser on a loopback origin with platform/m3u_disk_catalog.js loaded.
async (page) => page.evaluate(async () => {
  const owner = 'm3u-disk-qa-' + Date.now() + '-' + Math.random();
  const open = (id = owner) => {
    const bridge = TVBroM3uDiskCreate(id, {requireEncryption: true});
    return async (method, args = {}) => JSON.parse(await bridge(method, JSON.stringify(args)));
  };
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const call = open(), other = open(owner + '-other');
  const movie = (id, title, order, categoryId = 'movies') =>
    ({kind:'movie', id, title, order, categoryId, extra:{url:'https://invalid.example/private-token/' + id}});
  const episode = (parentId, title) => ({kind:'episode', id:'shared', title, parentId, order:1});
  const live = (id, title, order) => ({kind:'live', id, title, number:order, order});
  try {
    assert(await call('state') === null, 'new source started with saved data');
    let draft = await call('begin');
    await call('add', {draft, rows:[movie('last','Last Film',4),movie('first','Łódź Film',1),live('1','old',1),
      live('2','second',2),episode('season-a','Episode A'),episode('season-b','Episode B')]});
    await call('add', {draft, rows:[movie('first','Duplicate Film',5),movie('foreign','Foreign Film',2,'other'),
      movie('middle','Middle Film',3),live('1','new',4),
      {kind:'category', id:'movies', parentId:'movie', title:'Movies', order:1}]});
    assert((await call('read',{kind:'movie'})).items.length === 0, 'uncommitted rows are visible');
    const committed = await call('commit',{draft,header:{epgUrl:'https://invalid.example/private-header'}});
    assert(committed.counts.movie === 4 && committed.counts.live === 2, 'duplicates inflated counts');
    const restored = open();
    assert((await restored('state')).header.epgUrl.endsWith('/private-header'), 'header was lost after reopening');
    const page = await restored('read',{kind:'movie',categoryId:'movies',offset:1,limit:1});
    assert(page.count === 3 && page.hasMore && page.items[0].id === 'middle', 'category offset or total is wrong');
    const search = await restored('read',{kind:'movie',query:'ŁÓDŹ',limit:10});
    assert(search.items.length === 1 && search.items[0].title === 'Łódź Film', 'first movie or case-insensitive search was lost');
    assert((await restored('read',{kind:'live'})).items.map(row=>row.title).join() === 'second,new', 'live duplicate kept the wrong payload or order');
    assert((await restored('read',{kind:'live',ids:['1','missing','2']})).items.map(row=>row.id).join() === '1,2', 'favorite order or missing-ID handling is wrong');
    assert((await restored('get',{kind:'episode',id:'shared',parentId:'season-b'})).title === 'Episode B', 'episode ID was shared across parents');
    assert((await restored('read',{kind:'category',parentId:'movie'})).items[0].title === 'Movies', 'category parent could not be read');
    assert((await restored('get',{kind:'movie',id:'first'})).extra.url.endsWith('/private-token/first'), 'playback locator was lost');

    // Inspect real IndexedDB values, including the committed header, for plaintext locators.
    const stored = await new Promise((resolve,reject) => {
      const request = indexedDB.open('tvbro_m3u_disk_v1');
      request.onerror = () => reject(request.error);
      request.onsuccess = () => {
        const db = request.result, records = [];
        const transaction = db.transaction(['metadata','rows'], 'readonly');
        for (const name of ['metadata','rows']) {
          const request = transaction.objectStore(name).getAll();
          request.onsuccess = () => records.push(...request.result);
        }
        transaction.oncomplete = () => {db.close();resolve(records);};
        transaction.onabort = () => {db.close();reject(transaction.error);};
      };
    });
    assert(!JSON.stringify(stored).includes('invalid.example'), 'a protected locator was saved as plaintext');

    draft = await call('begin');
    await call('add',{draft,rows:[movie('staged','Staged Film',1)]});
    const add = IDBObjectStore.prototype.add;
    IDBObjectStore.prototype.add = function (value) {
      if (value.id === 'failed') throw new DOMException('Fixture disk full', 'QuotaExceededError');
      return add.apply(this,arguments);
    };
    try {
      const failure = await call('add',{draft,rows:[movie('partial','Partial Film',2),movie('failed','Fail',3)]});
      assert(failure?.__tvbroM3uDiskError === 'storage_full', 'a failed write did not report the storage error');
    } finally { IDBObjectStore.prototype.add = add; }
    await call('abort',{draft});
    assert((await restored('state')).counts.movie === 4, 'failed import replaced the previous catalogue');
    assert(await restored('get',{kind:'movie',id:'staged'}) === null, 'aborted catalogue is visible');

    const otherDraft = await other('begin');
    await other('add',{draft:otherDraft,rows:[movie('other-owner','Other Owner',1)]});
    await other('commit',{draft:otherDraft,header:{}});
    const abandoned = await call('begin');
    await call('add',{draft:abandoned,rows:[movie('abandoned','Abandoned',1)]});
    const updated = await restored('begin');
    await restored('add',{draft:updated,rows:[movie('updated','Updated',1)]});
    await restored('commit',{draft:updated,header:{}});
    assert((await call('read',{kind:'movie'})).items.map(row=>row.id).join() === 'updated', 'commit left a stale generation visible');
    await call('remove');
    assert(await call('state') === null, 'source removal retained its state');
    assert((await other('state')).counts.movie === 1, 'source removal affected another owner');
    return {status:'passed', publicReads:'paged, ordered, filtered and durable', storage:'atomic, owner-scoped and encrypted'};
  } finally {
    await call('remove');
    await other('remove');
  }
})
