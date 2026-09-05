# A Git server that speaks the protocol Argo CD actually uses.
#
# Argo CD's repo server is go-git, and go-git implements only the SMART HTTP
# transport: it sends `GET /repo.git/info/refs?service=git-upload-pack` and
# expects a pkt-line stream beginning `001e# service=git-upload-pack`. It has no
# fallback. A static file server answers that request with the plain refs file,
# go-git parses past the end of a 57-byte body, and the failure surfaces as
# "failed to list refs: unexpected EOF".
#
# The `git` CLI hides this: when the response is not smart-format it silently
# retries as dumb HTTP and succeeds, which is why testing with `git ls-remote`
# reports a healthy server that Argo CD cannot read. Test with go-git, or test
# the bytes.
#
# `git http-backend` is the smart server, and it is a CGI program. So this image
# is the smallest thing that can run CGI plus git: lighttpd's mod_cgi rather
# than nginx plus fcgiwrap, because nginx cannot run CGI directly and the
# FastCGI hop buys nothing here. Two packages, one process, no state.
#
# The base is pinned by digest. The two packages resolve to whatever that Alpine
# release carries, which is the honest limit of this pin: reproducible to the
# release, not to the package build. A registry this repo controlled would pin
# the built image itself and remove the question.
FROM alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

# git-daemon is where Alpine ships git-http-backend. The daemon itself is never
# run -- only the CGI binary in that package is used.
RUN apk add --no-cache git git-daemon lighttpd \
	&& git --version && lighttpd -version \
	# Fail the build rather than the pod if the CGI binary ever moves.
	&& test -x /usr/libexec/git-core/git-http-backend

# Serves on 8080 so the process never needs to be root or hold NET_BIND_SERVICE.
EXPOSE 8080
USER 100:101
ENTRYPOINT ["lighttpd", "-D", "-f", "/etc/lighttpd/lighttpd.conf"]
