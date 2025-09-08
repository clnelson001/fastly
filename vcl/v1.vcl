sub vcl_recv {
    #FASTLY recv

    # --- URL rewrites for S3 ---
    # Root: "/" or "/?qs" → "/index.html" (preserve qs)
    if (req.url.path == "/") {
      if (req.url.qs) {
        set req.url = "/index.html?" req.url.qs;
      } else {
        set req.url = "/index.html";
      }
    }

    # Folder: "/about/" or "/about/?qs" → "/about/index.html" (preserve qs)
    if (req.url.path ~ "/$" && req.url.path != "/") {
      if (req.url.qs) {
        set req.url = req.url.path "index.html?" req.url.qs;
      } else {
        set req.url = req.url.path "index.html";
      }
    }

    # --- Choose origin via Edge Dictionary (active_origin: origin -> primary|fallback) ---
    declare local var.origin_choice STRING;
    set var.origin_choice = table.lookup(active_origin, "origin", "primary");

    if (var.origin_choice == "fallback") {
      set req.backend = F_fallback;
      set req.http.X-Demo-Origin-Region = "us-east-2";
    } else {
      set req.backend = F_primary;
      set req.http.X-Demo-Origin-Region = "us-east-1";
    }
}

sub vcl_hash {
    #FASTLY hash
}

sub vcl_miss {
    #FASTLY miss
}

sub vcl_pass {
    #FASTLY pass
}

sub vcl_fetch {
    #FASTLY fetch

    # --- Surrogate keys ---
    if (bereq.url.path == "/" || bereq.url.path == "/index.html") {
      set beresp.http.Surrogate-Key = "page:index section:home";
    } else if (bereq.url.path ~ "^/about(/|$)") {
      set beresp.http.Surrogate-Key = "page:about section:about";
    } else if (bereq.url.path ~ "^/static/") {
      set beresp.http.Surrogate-Key = "static:all";
    } else {
      set beresp.http.Surrogate-Key = "misc";
    }
    set beresp.http.X-Surrogate-Keys = beresp.http.Surrogate-Key;

    # --- TTL from timers(demo-ttl): only allow 1m, 2m, 5m (default 2m) ---
    declare local var.ttl_cfg STRING;
    set var.ttl_cfg = table.lookup(timers, "demo-ttl", "2m");

    if (var.ttl_cfg == "1m") {
      set beresp.ttl = 1m;
    } else if (var.ttl_cfg == "5m") {
      set beresp.ttl = 5m;
    } else {
      set beresp.ttl = 2m;
      set var.ttl_cfg = "2m";
    }

    # --- Debug-only info (will be hidden unless debug is on) ---
    # What URL Fastly actually fetched (after rewrites)
    set beresp.http.X-Demo-Resolved-URL = bereq.url;
    # What Host we sent to S3 (useful to prove the bucket host)
    set beresp.http.X-Demo-Origin-Host = bereq.http.Host;
    # Chosen TTL string
    set beresp.http.X-Demo-Initial-TTL = var.ttl_cfg;
}

sub vcl_deliver {
    #FASTLY deliver

    # Basic debug headers you already had
    set resp.http.X-Cache      = if (obj.hits > 0, "HIT", "MISS");
    set resp.http.X-Cache-Hits = obj.hits;
    set resp.http.X-Served-By  = server.identity;

    declare local var.debug STRING;
    set var.debug = table.lookup(debug_flags, "debug", "off");

    if (var.debug == "on") {
      set resp.http.X-Demo-Debug      = "on";
      set resp.http.X-Demo-POP        = server.identity;
      set resp.http.X-Demo-Edge-Cache = if (obj.hits > 0, "HIT", "MISS");

      # Expose origin region and the debug-only headers when debug is on
      if (req.http.X-Demo-Origin-Region) {
        set resp.http.X-Demo-Origin-Region = req.http.X-Demo-Origin-Region;
      }
      # These headers were set in vcl_fetch; we just leave them visible here
      # (No need to copy from beresp/obj again)
    } else {
      # Hide debug-only headers for normal traffic
      unset resp.http.X-Demo-Origin-Region;
      unset resp.http.X-Demo-Initial-TTL;
      unset resp.http.X-Demo-Resolved-URL;
      unset resp.http.X-Demo-Origin-Host;
      unset resp.http.X-Demo-Debug;
      unset resp.http.X-Demo-POP;
      unset resp.http.X-Demo-Edge-Cache;
    }
}

sub vcl_log {
    #FASTLY log
}

sub vcl_error {
    #FASTLY error
}
