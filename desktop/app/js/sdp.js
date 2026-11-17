// Text surgery on session descriptions. GeForce NOW's offers need a few fixes before a
// stock WebRTC stack accepts them, and the answer travels with NVIDIA's own stream settings.

const dottedIp = /^\d{1,3}(\.\d{1,3}){3}$/;

/** "80-250-97-40.cloud.example" and "80.250.97.40" both mean 80.250.97.40. */
export function publicIp(host) {
  if (dottedIp.test(host)) return host;
  const parts = host.split('.')[0].split('-');
  return parts.length === 4 && parts.every((p) => /^\d{1,3}$/.test(p)) ? parts.join('.') : null;
}

/** The server writes 0.0.0.0 where its address belongs. Put the real one in. */
export function fixServerIp(sdp, server) {
  const ip = publicIp(server);
  if (!ip) return sdp;
  return sdp
    .replaceAll('c=IN IP4 0.0.0.0', `c=IN IP4 ${ip}`)
    .replace(/(a=candidate:\S+\s+\d+\s+\w+\s+\d+\s+)0\.0\.0\.0(\s+)/g, `$1${ip}$2`);
}

const lines = (sdp) => sdp.split(/\r?\n/);
const eol = (sdp) => (sdp.includes('\r\n') ? '\r\n' : '\n');
const codecName = (raw) => (raw.toUpperCase() === 'HEVC' ? 'H265' : raw.toUpperCase());

export function value(sdp, prefix) {
  const l = lines(sdp).find((x) => x.startsWith(prefix));
  return l ? l.slice(prefix.length).trim() : null;
}

export const credentials = (sdp) => ({
  ufrag: value(sdp, 'a=ice-ufrag:') ?? '',
  pwd: value(sdp, 'a=ice-pwd:') ?? '',
  fingerprint: value(sdp, 'a=fingerprint:sha-256 ') ?? '',
});

export function partialReliableThreshold(sdp) {
  const m = /a=ri\.partialReliableThresholdMs:(\d+)/i.exec(sdp);
  const n = m ? parseInt(m[1], 10) : 0;
  return n > 0 ? n : null;
}

/** Video codecs the offer contains, by name (H264, H265, AV1...). */
export function offeredCodecs(sdp) {
  const out = new Set();
  let video = false;
  for (const l of lines(sdp)) {
    if (l.startsWith('m=')) video = l.startsWith('m=video');
    if (video && l.startsWith('a=rtpmap:')) out.add(codecName(l.slice(l.indexOf(' ') + 1).split('/')[0]));
  }
  return out;
}

/** Leaves only `codec` and its retransmission streams in the video section. */
export function keepCodec(sdp, codec) {
  const all = lines(sdp);
  const nameOf = new Map();
  const aptOf = new Map();
  let video = false;
  for (const l of all) {
    if (l.startsWith('m=')) video = l.startsWith('m=video');
    if (!video) continue;
    if (l.startsWith('a=rtpmap:')) {
      nameOf.set(l.slice(9).split(' ')[0], codecName(l.slice(l.indexOf(' ') + 1).split('/')[0]));
    } else if (l.startsWith('a=fmtp:')) {
      const m = /(?:^|;)\s*apt=(\d+)/.exec(l.slice(l.indexOf(' ') + 1));
      if (m) aptOf.set(l.slice(7).split(' ')[0], m[1]);
    }
  }
  const wanted = new Set([...nameOf].filter(([, n]) => n === codec).map(([pt]) => pt));
  if (!wanted.size) return sdp;
  const allowed = new Set(wanted);
  for (const [pt, apt] of aptOf) if (wanted.has(apt) && nameOf.get(pt) === 'RTX') allowed.add(pt);
  const out = [];
  video = false;
  for (const l of all) {
    if (l.startsWith('m=')) video = l.startsWith('m=video');
    if (video && l.startsWith('m=video')) {
      const parts = l.split(' ');
      const pts = parts.slice(3).filter((p) => allowed.has(p));
      const ordered = [...pts.filter((p) => wanted.has(p)), ...pts.filter((p) => !wanted.has(p))];
      out.push(ordered.length ? [...parts.slice(0, 3), ...ordered].join(' ') : l);
      continue;
    }
    if (video && /^a=(rtpmap|fmtp|rtcp-fb):/.test(l)) {
      const pt = l.slice(l.indexOf(':') + 1).split(' ')[0];
      if (!allowed.has(pt)) continue;
    }
    out.push(l);
  }
  return out.join(eol(sdp));
}

/** The codec the answer settled on: the first payload type on the video line. */
export function negotiatedCodec(sdp) {
  const all = lines(sdp);
  const pt = all.find((l) => l.startsWith('m=video'))?.split(' ')[3];
  if (!pt) return null;
  const map = all.find((l) => l.startsWith(`a=rtpmap:${pt} `));
  return map ? codecName(map.slice(map.indexOf(' ') + 1).split('/')[0]) : null;
}

/** Tells the server how much we can take, and asks for stereo game audio. */
export function mungeAnswer(sdp, videoKbps) {
  const all = lines(sdp);
  const out = [];
  all.forEach((l, i) => {
    out.push(l.startsWith('a=fmtp:') && l.includes('minptime=') && !l.includes('stereo=1') ? `${l};stereo=1` : l);
    const video = l.startsWith('m=video');
    if ((video || l.startsWith('m=audio')) && !all[i + 1]?.startsWith('b=')) out.push(`b=AS:${video ? videoKbps : 128}`);
  });
  return out.join(eol(sdp));
}

export const MIN_KBPS = 20000;

/**
 * NVIDIA's companion description. It repeats the ICE credentials and carries the encoder and
 * pacing settings the server applies: a fixed resolution, adaptive bitrate with a floor, and
 * the high frame rate tuning from 90 fps up.
 */
export function nvst(p) {
  const minKbps = Math.min(p.maxKbps, Math.max(MIN_KBPS, Math.floor((p.maxKbps * 35) / 100)));
  const startKbps = Math.max(minKbps, Math.floor((p.maxKbps * 70) / 100));
  const highFps = p.fps >= 90;
  const fps120 = p.fps === 120;
  const av1 = p.codec === 'AV1';
  const o = ['v=0', 'o=SdpTest test_id_13 14 IN IPv4 127.0.0.1', 's=-', 't=0 0'];
  const a = (s) => o.push(`a=${s}`);
  a(`general.icePassword:${p.ice.pwd}`);
  a(`general.iceUserNameFragment:${p.ice.ufrag}`);
  a(`general.dtlsFingerprint:${p.ice.fingerprint}`);
  o.push('m=video 0 RTP/AVP');
  for (const s of [
    'msid:fbc-video-0', 'vqos.fec.rateDropWindow:10', 'vqos.fec.minRequiredFecPackets:2', 'vqos.fec.repairMinPercent:5',
    'vqos.fec.repairPercent:5', 'vqos.fec.repairMaxPercent:35', 'vqos.drc.enable:0', 'vqos.dfc.enable:0',
    'video.dx9EnableNv12:1', 'video.dx9EnableHdr:1', 'vqos.qpg.enable:1', 'vqos.resControl.qp.qpg.featureSetting:7',
    'bwe.useOwdCongestionControl:1', 'video.enableRtpNack:1', 'vqos.bw.txRxLag.minFeedbackTxDeltaMs:200',
    'vqos.drc.bitrateIirFilterFactor:18', 'video.packetSize:1140', 'packetPacing.minNumPacketsPerGroup:15',
  ]) a(s);
  if (highFps) {
    a('bwe.iirFilterFactor:8');
    a('video.encoderFeatureSetting:47');
    a('video.encoderPreset:6');
    a('vqos.resControl.cpmRtc.badNwSkipFramesCount:600');
    a('vqos.resControl.cpmRtc.decodeTimeThresholdMs:9');
    a(`video.fbcDynamicFpsGrabTimeoutMs:${fps120 ? 6 : 18}`);
    a(`vqos.resControl.cpmRtc.serverResolutionUpdateCoolDownCount:${fps120 ? 6000 : 12000}`);
  }
  if (p.fps >= 240) {
    a('video.enableNextCaptureMode:1');
    a('vqos.maxStreamFpsEstimate:240');
    a('video.videoSplitEncodeStripsPerFrame:3');
    a('video.updateSplitEncodeStateDynamically:1');
  }
  for (const s of [
    'vqos.adjustStreamingFpsDuringOutOfFocus:1', 'vqos.resControl.cpmRtc.ignoreOutOfFocusWindowState:1',
    'vqos.resControl.perfHistory.rtcIgnoreOutOfFocusWindowState:1', 'vqos.resControl.cpmRtc.featureMask:0',
    'vqos.resControl.cpmRtc.enable:0', 'vqos.resControl.cpmRtc.minResolutionPercent:100',
    'vqos.resControl.cpmRtc.resolutionChangeHoldonMs:999999', `packetPacing.numGroups:${fps120 ? 3 : 5}`,
    'packetPacing.maxDelayUs:1000', 'packetPacing.minNumPacketsFrame:10', 'video.rtpNackQueueLength:1024',
    'video.rtpNackQueueMaxPackets:512', 'video.rtpNackMaxPacketCount:25', 'vqos.drc.qpMaxResThresholdAdj:4',
    'vqos.grc.qpMaxResThresholdAdj:4', 'vqos.drc.iirFilterFactor:100',
  ]) a(s);
  if (av1) {
    for (const k of ['drc', 'grc']) {
      a(`vqos.${k}.minQpHeadroom:20`);
      a(`vqos.${k}.lowerQpThreshold:100`);
      a(`vqos.${k}.upperQpThreshold:200`);
      a(`vqos.${k}.minAdaptiveQpThreshold:180`);
      a(`vqos.${k}.qpCodecThresholdAdj:0`);
      a(`vqos.${k}.qpMaxResThresholdAdj:20`);
    }
    for (const s of [
      'vqos.dfc.minQpHeadroom:20', 'vqos.dfc.qpLowerLimit:100', 'vqos.dfc.qpMaxUpperLimit:200', 'vqos.dfc.qpMinUpperLimit:180',
      'vqos.dfc.qpMaxResThresholdAdj:20', 'vqos.dfc.qpCodecThresholdAdj:0', 'video.minQp:25', 'video.enableAv1RcPrecisionFactor:1',
    ]) a(s);
  }
  a(`video.clientViewportWd:${p.viewportWidth}`);
  a(`video.clientViewportHt:${p.viewportHeight}`);
  a(`video.maxFPS:${p.fps}`);
  a(`video.initialBitrateKbps:${startKbps}`);
  a(`video.initialPeakBitrateKbps:${p.maxKbps}`);
  a(`vqos.bw.maximumBitrateKbps:${p.maxKbps}`);
  a(`vqos.bw.minimumBitrateKbps:${minKbps}`);
  a(`vqos.bw.peakBitrateKbps:${p.maxKbps}`);
  a(`vqos.bw.serverPeakBitrateKbps:${p.maxKbps}`);
  a('vqos.bw.enableBandwidthEstimation:1');
  a('vqos.bw.disableBitrateLimit:0');
  a(`vqos.grc.maximumBitrateKbps:${p.maxKbps}`);
  a('vqos.grc.enable:0');
  a('video.maxNumReferenceFrames:4');
  a('video.mapRtpTimestampsToFrames:1');
  a('video.encoderCscMode:3');
  a('video.dynamicRangeMode:0');
  a(`video.bitDepth:${p.bitDepth}`);
  a(`video.scalingFeature1:${av1 ? 1 : 0}`);
  a('video.prefilterParams.prefilterModel:0');
  o.push('m=audio 0 RTP/AVP');
  a('msid:audio');
  o.push('m=mic 0 RTP/AVP');
  a('msid:mic');
  a('rtpmap:0 PCMU/8000');
  o.push('m=application 0 RTP/AVP');
  a('msid:input_1');
  a(`ri.partialReliableThresholdMs:${p.partialReliableMs}`);
  return o.join('\n') + '\n';
}
