// Viewer-request function: injects the viewer's IP as `true-client-ip` on
// every request (AD-12, spec §5.10). Assigning unconditionally means a
// client-supplied value never survives, and the origin request policy
// (AllViewerExceptHostHeader) forwards it like any other viewer header.
function handler(event) {
    var request = event.request;
    request.headers['true-client-ip'] = { value: event.viewer.ip };
    return request;
}
