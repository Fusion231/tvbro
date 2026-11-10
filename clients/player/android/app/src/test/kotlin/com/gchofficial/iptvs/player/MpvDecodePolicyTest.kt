package com.gchofficial.iptvs.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvDecodePolicyTest {
    @Test fun knownNonDvVideoMayTryHardware() {
        assertTrue(MpvDecodePolicy.hardwareDecodeAllowed("video/avc", "avc1.640028"))
        assertTrue(MpvDecodePolicy.hardwareDecodeAllowed("video/hevc", "hvc1.2.4.L153"))
        assertTrue(MpvDecodePolicy.hardwareDecodeAllowed("video/av01", null))
    }

    @Test fun dolbyVisionKeepsSoftwareEvenWithAHevcMimeType() {
        assertFalse(MpvDecodePolicy.hardwareDecodeAllowed("video/dolby-vision", "dvhe.05.06"))
        assertFalse(MpvDecodePolicy.hardwareDecodeAllowed("video/hevc", "hvc1.2, DVH1.05.06"))
        assertFalse(MpvDecodePolicy.hardwareDecodeAllowed("video/hevc", "dvhe.08.06"))
        assertFalse(MpvDecodePolicy.hardwareDecodeAllowed("video/av01", "dav1.10.09"))
    }

    @Test fun unknownFormatsKeepTheExistingSoftwarePath() {
        assertFalse(MpvDecodePolicy.hardwareDecodeAllowed(null, null))
        assertFalse(MpvDecodePolicy.hardwareDecodeAllowed("", "hvc1"))
        assertFalse(MpvDecodePolicy.hardwareDecodeAllowed("audio/aac", "mp4a"))
        assertFalse(MpvDecodePolicy.hardwareDecodeAllowed("video/x-unknown", null))
        assertFalse(MpvDecodePolicy.hardwareDecodeAllowed("video/future-codec", "new1"))
    }

    @Test fun hardwarePermissionDoesNotSurviveAChannelChangeOrReload() {
        val knownFirstStream = MpvLoadDecodePolicy(true)
        org.junit.Assert.assertEquals("mediacodec-copy", knownFirstStream.nextHwdec())
        org.junit.Assert.assertEquals("no", knownFirstStream.nextHwdec())
        org.junit.Assert.assertEquals("no", knownFirstStream.nextHwdec())
        org.junit.Assert.assertEquals("no", MpvLoadDecodePolicy(false).nextHwdec())
    }
}
