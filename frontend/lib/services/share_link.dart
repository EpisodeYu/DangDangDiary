import '../config/constants.dart';

/// Build the URL embedded into a share QR code for [code].
///
/// The URL form is preferred over a raw `DDDIARY:` magic string so a
/// future Web landing page can be wired up without re-issuing already
/// printed QR codes. `parseShareCode` is the single source of truth
/// for "is this string something we accept", whether it arrived from a
/// camera scan, a gallery analyse-image call, or a manual paste.
String buildShareUrl(String code) => '${AppConstants.shareLinkBaseUrl}$code';

/// Extract a valid 8-character share code from an arbitrary scanned
/// payload. Accepts:
///   - `<scheme>://<host>/s/<code>` where `host` is in
///     [AppConstants.shareLinkHosts] (scheme http/https both ok so
///     debug builds and a future plain-text fallback still work)
///   - the 8-char code on its own (manual paste / typed entry)
///
/// Returns the normalised upper-case code on success, `null` when the
/// payload is anything else (a random URL, another QR app, garbage).
/// The caller MUST treat `null` as "this isn't a 当当日记 share QR" and
/// show the standard rejection message.
String? parseShareCode(String payload) {
  final trimmed = payload.trim();
  if (trimmed.isEmpty) return null;

  // 1) Bare 8-character code (manual paste / typed entry / scanner
  //    returning just the code if a partner site ever embeds it).
  final upper = trimmed.toUpperCase();
  if (AppConstants.shareCodePattern.hasMatch(upper)) return upper;

  // 2) URL form.
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;
  if (!AppConstants.shareLinkHosts.contains(uri.host.toLowerCase())) {
    return null;
  }
  if (uri.pathSegments.length != 2) return null;
  if (uri.pathSegments[0] != 's') return null;
  final code = uri.pathSegments[1].toUpperCase();
  if (!AppConstants.shareCodePattern.hasMatch(code)) return null;
  return code;
}
