# -------------------------
# Custom rules
# -------------------------

sub vcl_recv {
  #FASTLY recv
  # --- URL rewrites for S3 ---
  if (req.url.path == "/") {
    if (req.url.qs) {
      set req.url = "/index.html?" req.url.qs;
    } else {
      set req.url = "/index.html";
    }
  }

  if (req.url.path ~ "/$" && req.url.path != "/") {
    if (req.url.qs) {
      set req.url = req.url.path "index.html?" req.url.qs;
    } else {
      set req.url = req.url.path "index.html";
    }
  }

  if (req.url.path == "/hello" && req.url.qs ~ "(^|&)lang=") {
    declare local var.lang STRING;
    set var.lang = querystring.get(req.url, "lang");
    set req.url = "/hello_" + var.lang + ".html";
  }

  # --- Choose origin via Edge Dictionary ---
  declare local var.origin_choice STRING;
  set var.origin_choice = table.lookup(active_origin, "origin", "primary");

  if (var.origin_choice == "fallback") {
    set req.backend = F_fallback;
    set req.http.X-Demo-Origin-Region = "us-east-2";
  } else {
    set req.backend = F_primary;
    set req.http.X-Demo-Origin-Region = "us-east-1";
  }

  # --- Apply shielding after backend selection ---
   if (req.restarts == 0) {
    if (req.backend == F_primary) {
      set req.backend = fastly.try_select_shield(ssl_shield_iad_va_us, F_primary);
    } else if (req.backend == F_fallback) {
      set req.backend = fastly.try_select_shield(ssl_shield_chi_il_us, F_fallback);
    }
  }
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

  # --- TTL from timers dict ---
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

  # --- Debug info ---
  set beresp.http.X-Demo-Resolved-URL = bereq.url;
  set beresp.http.X-Demo-Origin-Host  = bereq.http.Host;
  set beresp.http.X-Demo-Initial-TTL  = var.ttl_cfg;
}

sub vcl_deliver {
  #FASTLY deliver
  declare local var.debug STRING;
  set var.debug = table.lookup(debug_flags, "debug", "off");

  if (var.debug == "on") {
    set resp.http.X-Demo-Debug      = "on";
    set resp.http.X-Demo-POP        = server.identity;
    set resp.http.X-Demo-Edge-Cache = if (obj.hits > 0, "HIT", "MISS");

    if (req.http.X-Demo-Origin-Region) {
      set resp.http.X-Demo-Origin-Region = req.http.X-Demo-Origin-Region;
    }
  } else {
    unset resp.http.X-Demo-Origin-Region;
    unset resp.http.X-Demo-Initial-TTL;
    unset resp.http.X-Demo-Resolved-URL;
    unset resp.http.X-Demo-Origin-Host;
    unset resp.http.X-Demo-Debug;
    unset resp.http.X-Demo-POP;
    unset resp.http.X-Demo-Edge-Cache;
  }

  # Keep boilerplate X-Served-By/X-Cache intact (don’t overwrite!)
}