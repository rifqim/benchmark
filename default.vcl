#
# This is an example VCL file for Varnish.
#
# It does not do anything by default, delegating control to the
# builtin VCL. The builtin VCL is called when there is no explicit
# return statement.
#
# See the VCL chapters in the Users Guide at https://www.varnish-cache.org/docs/
# and http://varnish-cache.org/trac/wiki/VCLExamples for more examples.

# Marker to tell the VCL compiler that this VCL has been adapted to the
# new 4.0 format.
vcl 4.0;

import directors;
import std;

# Default backend definition. Set this to point to your content server.
backend default {
    .host = "127.0.0.1";
    .port = "8899";
}

acl purge {
	"localhost";
	"127.0.0.1";
	"::1";
}

sub vcl_init {
	# Called when VCL is loaded, before any requests pass through it.
	# Typically used to initialize VMODs.

	new vdir = directors.round_robin();
	vdir.add_backend(default);
}

sub purge_regex {
	# Custom made function for handling regex purges

	ban("obj.http.X-Req-URL ~ " + req.url + " && obj.http.X-Req-Host == " + req.http.host);
}

sub purge_exact {
	# Custom made function for handling exact purges

	ban("obj.http.X-Req-URL == " + req.url + " && obj.http.X-Req-Host == " + req.http.host);
}

sub purge_page {
	# Custom made function for handling page purges

	set req.url = regsub(req.url, "\?.*$", "");
	ban("obj.http.X-Req-URL-Base == " + req.url + " && obj.http.X-Req-Host == " + req.http.host);
}

sub vcl_recv {
	# Called at the beginning of a request, after the complete request has been received and parsed.
	# Its purpose is to decide whether or not to serve the request, how to do it, and, if applicable,
	# which backend to use.
	# also used to modify the request

	set req.backend_hint = vdir.backend();

	# Normalize the header, remove the port (in case you're testing this on various TCP ports)
	set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");

	# Normalize the query arguments
	set req.url = std.querysort(req.url);

	if (req.restarts == 0) {
		if (req.http.X-Forwarded-For) {
			set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
		} else {
			set req.http.X-Forwarded-For = client.ip;
		}
	}

	if (req.method == "PURGE") {
		if (! client.ip ~ purge) {
			return(synth(405,"Not allowed."));
		}
		if (req.http.X-Purge-Method) {
			if (req.http.X-Purge-Method ~ "(?i)regex") {
				call purge_regex;
			} elsif (req.http.X-Purge-Method ~ "(?i)exact") {
				call purge_exact;
			} else {
				call purge_page;
			}
		} else {
			# No X-Purge-Method header was specified.
			# Do our best to figure out which one they want.
			if (req.url ~ "\.\*" || req.url ~ "^\^" || req.url ~ "\$$" || req.url ~ "\\[.?*+^$|()]") {
				call purge_regex;
			} elsif (req.url ~ "\?") {
				call purge_exact;
			} else {
				call purge_page;
			}
		}
		return(synth(200,"Purged."));

	}
	
	# Only deal with "normal" types
	if (req.method != "GET" &&
		req.method != "HEAD" &&
		req.method != "PUT" &&
		req.method != "POST" &&
		req.method != "TRACE" &&
		req.method != "OPTIONS" &&
		req.method != "PATCH" &&
		req.method != "DELETE") {
		/* Non-RFC2616 or CONNECT which is weird. */
		return(pipe);
	}

	# Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
	if (req.http.Upgrade ~ "(?i)websocket") {
		return(pipe);
	}

	# Only cache GET or HEAD requests. This makes sure the POST requests are always passed.
	if (req.method != "GET" && req.method != "HEAD") {
		return(pass);
	}

	# We don’t interfere with auth requests
	if (req.http.Authorization) {
		return(pass);
	}

	# User is logged in. Pass to backend.
	if (req.http.cookie ~ "wordpress_logged_in_") {
		return(pass);
	}

	# WordPress requests we don’t want to cache
	if (req.url ~ "wp-(login|admin|signup|cron|activate|mail)" && req.url !~ "preview=true" && req.http.Cookie !~ "wp-postpass") {
		return(pass);
	}

	# At this point we can get rid of all cookies
	unset req.http.cookie;

	# Strip hash, server doesn't need it.
	if (req.url ~ "\#") {
		set req.url = regsub(req.url, "\#.*$", "");
	}

	# Strip a trailing ? if it exists
	if (req.url ~ "\?$") {
		set req.url = regsub(req.url, "\?$", "");
	}

	# Normalize Accept-Encoding header
	if (req.http.Accept-Encoding) {
		if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg|woff)$") {
			# No point in compressing these
			unset req.http.Accept-Encoding;
		} elseif (req.http.Accept-Encoding ~ "gzip") {
			set req.http.Accept-Encoding = "gzip";
		} elseif (req.http.Accept-Encoding ~ "deflate") {
			set req.http.Accept-Encoding = "deflate";
		} else {
			# unkown algorithm
			unset req.http.Accept-Encoding;
		}
	}

	# Send Surrogate-Capability headers to announce ESI support to backend
	set req.http.Surrogate-Capability = "key=ESI/1.0";

	return(hash);

}

sub vcl_pipe {
	# Called upon entering pipe mode.
	# In this mode, the request is passed on to the backend, and any further data from both the client
	# and backend is passed on unaltered until either end closes the connection. Basically, Varnish will
	# degrade into a simple TCP proxy, shuffling bytes back and forth. For a connection in pipe mode,
	# no other VCL subroutine will ever get called after vcl_pipe.

	# Note that only the first request to the backend will have
	# X-Forwarded-For set.  If you use X-Forwarded-For and want to
	# have it set for all requests, make sure to have:
	# set bereq.http.connection = "close";
	# here.  It is not set by default as it might break some broken web
	# applications, like IIS with NTLM authentication.

	set bereq.http.Connection = "Close";

	# Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
	if (req.http.upgrade) {
		set bereq.http.upgrade = req.http.upgrade;
	}

	return (pipe);
}

sub vcl_pass {
  # Called upon entering pass mode. In this mode, the request is passed on to the backend, and the
  # backend's response is passed on to the client, but is not entered into the cache. Subsequent
  # requests submitted over the same client connection are handled normally.

  # return (pass);
}

sub vcl_hash {
	hash_data(req.url);

	if (req.http.host) {
		hash_data(req.http.host);
	} else {
		hash_data(server.ip);
	}

	# If the client supports compression, keep that in a different cache
	if (req.http.Accept-Encoding) {
		hash_data(req.http.Accept-Encoding);
	}

	# hash cookies for requests that have them
	if (req.http.Cookie) {
		hash_data(req.http.Cookie);
	}

	return(lookup);
}

sub vcl_hit {
	# Called when a cache lookup is successful.

	# For limited/full grace control, look at this: https://info.varnish-software.com/blog/grace-varnish-4-stale-while-revalidate-semantics-varnish
}

sub vcl_backend_response {
	# Called after the response headers has been successfully retrieved from the backend.

	# Pause ESI request and remove Surrogate-Control header
	if (beresp.http.Surrogate-Control ~ "ESI/1.0") {
		unset beresp.http.Surrogate-Control;
		set beresp.do_esi = true;
	}


	# Large static files are delivered directly to the end-user without
	# waiting for Varnish to fully read the file first.
	# Varnish 4 fully supports Streaming, so use streaming here to avoid locking.
	if (bereq.url ~ "^[^?]*\.(7z|avi|bz2|flac|flv|gz|mka|mkv|mov|mp3|mp4|mpeg|mpg|ogg|ogm|opus|rar|tar|tgz|tbz|txz|wav|webm|xz|zip)(\?.*)?$") {
		unset beresp.http.set-cookie;
		set beresp.do_stream = true;  # Check memory usage it'll grow in fetch_chunksize blocks (128k by default) if the backend doesn't send a Content-Length header, so only enable it for big objects
		set beresp.do_gzip   = false;   # Don't try to compress it for storage
	}

	# Sometimes, a 301 or 302 redirect formed via Apache's mod_rewrite can mess with the HTTP port that is being passed along.
	# This often happens with simple rewrite rules in a scenario where Varnish runs on :80 and Apache on :8080 on the same box.
	# A redirect can then often redirect the end-user to a URL on :8080, where it should be :80.
	# This may need finetuning on your setup.
	#
	# To prevent accidental replace, we only filter the 301/302 redirects for now.
	if (beresp.status == 301 || beresp.status == 302) {
		set beresp.http.Location = regsub(beresp.http.Location, ":[0-9]+", "");
	}

	# Respect the Cache-Control=private header from the backend
	if (beresp.http.Cache-Control ~ "private") {
		set beresp.uncacheable = true;
		set beresp.ttl = 0s;
		return(deliver);
	}

	# Don't store backend
	if (bereq.url ~ "wp-(login|admin|signup|cron|activate|mail)" && bereq.url !~ "preview=true" && bereq.http.Cookie !~ "wp-postpass") {
		set beresp.uncacheable = true;
		set beresp.ttl = 0s;
		return(deliver);
	} else {
		# No cookies, thank you
		unset beresp.http.set-cookie;
	}

	# Cache HTML for 1s as default if no expires header is set or if less than 0
	if (beresp.ttl <= 0s && beresp.http.content-type ~ "text/html") {
		set beresp.ttl = 1s;
	}

	# Keep object in cache for 1w beyond the ttl to serve stale content (e.g. to the thundering herd or if the backend goes down)
	set beresp.grace = 1w;

	# Avoid caching error responses
	if (beresp.status == 404 || beresp.status >= 500) {
		set beresp.ttl   = 0s;
		set beresp.grace = 1s;
	}

	return(deliver);
}

sub vcl_deliver {
	# Called before a cached object is delivered to the client.

	if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    	} else {
        set resp.http.X-Cache = "MISS";
    	}

    	#set resp.http.X-Varnish;
    	set resp.http.X-C = obj.hits;
    	#set resp.http.IP = client.ip;
    	#set resp.http.Via;
    	#unset resp.http.X-Cache;
    	unset resp.http.X-Jp-Session;
    	unset resp.http.Server;
    	unset resp.http.X-Server-Node;
	#Iset resp.http.X-Powered-By;	

	return(deliver);
}

sub vcl_synth {
	if (resp.status == 720) {
		# We use this special error status 720 to force redirects with 301 (permanent) redirects
		# To use this, call the following from anywhere in vcl_recv: return (synth(720, "http://host/new.html"));
		set resp.http.Location = resp.reason;
		set resp.status = 301;
		return (deliver);
		} elseif (resp.status == 721) {
		# And we use error status 721 to force redirects with a 302 (temporary) redirect
		# To use this, call the following from anywhere in vcl_recv: return (synth(720, "http://host/new.html"));
		set resp.http.Location = resp.reason;
		set resp.status = 302;
		return (deliver);
	}

	return (deliver);
}


sub vcl_fini {
  # Called when VCL is discarded only after all requests have exited the VCL.
  # Typically used to clean up VMODs.

  return (ok);
}
