'use strict';

require('./service').start(require('webos-service'), require('./store').create());
