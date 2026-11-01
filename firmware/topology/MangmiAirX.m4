# SPDX-License-Identifier: BSD-3-Clause
# Mangmi Air X / Air Y (SM6115): AW88261 speakers on SEC MI2S, ES8326
# headphones and headset mic on QUAT MI2S, DMIC on the VA macro
include(`audioreach/audioreach.m4')
include(`audioreach/stream-subgraph.m4')
include(`audioreach/device-subgraph.m4')
include(`util/route.m4')
include(`util/mixer.m4')
include(`audioreach/tokens.m4')
#
# Stream SubGraphs
#
dnl Playback MultiMedia1
STREAM_SG_PCM_ADD(audioreach/subgraph-stream-vol-playback.m4, FRONTEND_DAI_MULTIMEDIA1,
	`S16_LE', 48000, 48000, 2, 2,
	0x00004001, 0x00004001, 0x00006001, `0')
dnl
dnl Playback MultiMedia2
STREAM_SG_PCM_ADD(audioreach/subgraph-stream-vol-playback.m4, FRONTEND_DAI_MULTIMEDIA2,
	`S16_LE', 48000, 48000, 2, 2,
	0x00004002, 0x00004002, 0x00006010, `0')
dnl
dnl Capture MultiMedia4
STREAM_SG_PCM_ADD(audioreach/subgraph-stream-capture.m4, FRONTEND_DAI_MULTIMEDIA4,
	`S16_LE', 48000, 48000, 1, 2,
	0x00004004, 0x00004004, 0x00006030, `0')
dnl
dnl Capture MultiMedia5
STREAM_SG_PCM_ADD(audioreach/subgraph-stream-capture.m4, FRONTEND_DAI_MULTIMEDIA5,
	`S16_LE', 48000, 48000, 1, 2,
	0x00004003, 0x00004003, 0x00006020, `0')
#
# Device SubGraphs
#
dnl Speaker Playback (MI2S-LPAIF_WSA-RX-PRIMARY)
DEVICE_SG_ADD(audioreach/subgraph-device-i2s-playback.m4, `Secondary', SECONDARY_MI2S_RX,
	`S16_LE', 48000, 48000, 2, 2,
	LPAIF_INTF_TYPE_WSA, I2S_INTF_TYPE_PRIMARY, SD_LINE_IDX_I2S_SD0, DATA_FORMAT_FIXED_POINT,
	0x00004005, 0x00004005, 0x00006050, `SEC_MI2S_RX')
dnl
dnl Headphone Playback (MI2S-LPAIF_RXTX-RX-PRIMARY)
DEVICE_SG_ADD(audioreach/subgraph-device-i2s-playback.m4, `Quaternary', QUATERNARY_MI2S_RX,
	`S16_LE', 48000, 48000, 2, 2,
	LPAIF_INTF_TYPE_RXTX, I2S_INTF_TYPE_PRIMARY, SD_LINE_IDX_I2S_SD0, DATA_FORMAT_FIXED_POINT,
	0x00004007, 0x00004007, 0x00006070, `QUAT_MI2S_RX')
dnl
dnl Headset Mic Capture (MI2S-LPAIF_RXTX-TX-PRIMARY)
DEVICE_SG_ADD(audioreach/subgraph-device-i2s-capture.m4, `Quaternary', QUATERNARY_MI2S_TX,
	`S16_LE', 48000, 48000, 1, 2,
	LPAIF_INTF_TYPE_RXTX, I2S_INTF_TYPE_PRIMARY, SD_LINE_IDX_I2S_SD1, DATA_FORMAT_FIXED_POINT,
	0x00004009, 0x00004009, 0x00006090, `QUAT_MI2S_TX')
dnl
dnl DMIC Capture (CODEC_DMA-LPAIF_VA-TX-0)
DEVICE_SG_ADD(audioreach/subgraph-device-codec-dma-capture.m4, `VA_CODEC_DMA_TX_0', VA_CODEC_DMA_TX_0,
	`S16_LE', 48000, 48000, 1, 2,
	LPAIF_INTF_TYPE_VA, CODEC_INTF_IDX_TX0, 0, DATA_FORMAT_FIXED_POINT,
	0x0000400B, 0x0000400B, 0x000060B0)
dnl
STREAM_DEVICE_PLAYBACK_MIXER(SECONDARY_MI2S_RX, ``SEC_MI2S_RX'', ``MultiMedia1'', ``MultiMedia2'')
STREAM_DEVICE_PLAYBACK_ROUTE(SECONDARY_MI2S_RX, ``SEC_MI2S_RX Audio Mixer'', ``MultiMedia1, stream0.logger1'', ``MultiMedia2, stream1.logger1'')
dnl
STREAM_DEVICE_PLAYBACK_MIXER(QUATERNARY_MI2S_RX, ``QUAT_MI2S_RX'', ``MultiMedia1'', ``MultiMedia2'')
STREAM_DEVICE_PLAYBACK_ROUTE(QUATERNARY_MI2S_RX, ``QUAT_MI2S_RX Audio Mixer'', ``MultiMedia1, stream0.logger1'', ``MultiMedia2, stream1.logger1'')
dnl
STREAM_DEVICE_CAPTURE_MIXER(FRONTEND_DAI_MULTIMEDIA4, ``QUAT_MI2S_TX'', ``VA_CODEC_DMA_TX_0'')
STREAM_DEVICE_CAPTURE_ROUTE(FRONTEND_DAI_MULTIMEDIA4, ``MultiMedia4 Mixer'', ``QUAT_MI2S_TX, device23.logger1'', ``VA_CODEC_DMA_TX_0, device110.logger1'')
dnl
STREAM_DEVICE_CAPTURE_MIXER(FRONTEND_DAI_MULTIMEDIA5, ``QUAT_MI2S_TX'', ``VA_CODEC_DMA_TX_0'')
STREAM_DEVICE_CAPTURE_ROUTE(FRONTEND_DAI_MULTIMEDIA5, ``MultiMedia5 Mixer'', ``QUAT_MI2S_TX, device23.logger1'', ``VA_CODEC_DMA_TX_0, device110.logger1'')
