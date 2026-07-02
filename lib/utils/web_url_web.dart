import 'dart:html' as html;

/// After a sign-out/switch-account, the browser's address bar (Uri.base) may
/// still carry the original invite link's query params (groupId/phone/invite/
/// code) — Flutter web is a single-page app, so the URL never actually
/// navigates away on its own. Left alone, the next AuthScreen re-reads
/// Uri.base and re-triggers the join flow for someone who already joined.
/// Rebuilds the URL from just scheme/host/port/path (dropping the query
/// string) via history.replaceState, so Uri.base is the plain app URL again.
void clearInviteFromBrowserUrl() {
  final uri = Uri.base;
  if (uri.queryParameters.isEmpty) return;
  // Keep the fragment (Flutter web's own route hash) — only the query string
  // (the invite params) needs to go.
  final clean = Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    fragment: uri.fragment.isEmpty ? null : uri.fragment,
  ).toString();
  html.window.history.replaceState(null, '', clean);
}
