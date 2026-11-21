package com.gchofficial.iptvs.player

import org.junit.Test

class ExoMediaSourceDependenciesTest {
    @Test
    fun `Media3 can load its DASH media source factory`() {
        // DefaultMediaSourceFactory uses reflection and crashes on .mpd when this is missing.
        Class.forName(
            "androidx.media3.exoplayer.dash.DashMediaSource\$Factory",
            false,
            javaClass.classLoader,
        )
    }
}
