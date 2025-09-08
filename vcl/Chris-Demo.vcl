sub vcl_recv { 
#FASTLY recv

  # Normally, you should consider requests other than GET and HEAD to be uncacheable
  # (to this we add the special FASTLYPURGE method)
  if (req.method != "HEAD" && req.method != "GET" && req.method != "FASTLYPURGE") {
    return(pass);
  }
  # --- Chris's recv additons -------------------->
  # --- URL rewrites for S3 root ---
  set req.http.X-Demo-Orig-URL = "https://" req.http.Host req.url;
  if (req.url.path == "/") {
    if (req.url.qs) {
      set req.url = "/index.html?" req.url.qs;
    } else {
      set req.url = "/index.html";
    }
  }
  # --- If path ends in '/', but not root... ---
  # --- Set to <path>/index.html, keep the query param if it exists
  if (req.url.path ~ "/$" && req.url.path != "/") {
    if (req.url.qs) {
      set req.url = req.url.path "index.html?" req.url.qs;
    } else {
      set req.url = req.url.path "index.html";
    }
  }
  # --- Set default language for hello page ---
  if (req.url.path == "/hello.html") {
    set req.url = "/hello_en.html";
  }
  if (req.url.path == "/503") {
    set req.url = "/503/index.html";
  }
  # --- now handle the specifc language requests [en|sp|fr] ---
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

  # --- Apply shielding AFTER backend selection ---
  if (req.restarts == 0) {
    if (req.backend == F_primary) {
      set req.backend = fastly.try_select_shield(ssl_shield_iad_va_us, F_primary);
    } else if (req.backend == F_fallback) {
      set req.backend = fastly.try_select_shield(ssl_shield_chi_il_us, F_fallback);
    }
  }# On the restarted request, route to the secondary origin once
  else if (req.restarts > 0 && req.http.X-Failover == "1") {
    set req.backend = fastly.try_select_shield(ssl_shield_chi_il_us, F_fallback);
    unset req.http.X-Failover;       # prevent further hops
  }

  # --- END Chris's recv additons -------------------->

  # If you are using image optimization, insert the code to enable it here
  # See https://www.fastly.com/documentation/reference/io/ for more information.

  return(lookup);
}

sub vcl_hash {
  set req.hash += req.url;
  set req.hash += req.http.host;
  #FASTLY hash
  return(hash);
}

sub vcl_hit {
#FASTLY hit
  return(deliver);
}

sub vcl_miss {
#FASTLY miss
  return(fetch);
}

sub vcl_pass {
#FASTLY pass
  return(pass);
}

sub vcl_fetch {
#FASTLY fetch
  #--- Chris's fetch additions --------->
  
    #AWS Returns 403 if unknown object is requested from S3
  #Treat it as a 404 or 503 instead
  if (beresp.status == 403 && bereq.url.path == "^/503(?:/|$)") {
    if (req.restarts == 0) {
      set beresp.http.X-Demo-Orig-Status = beresp.status;
      set beresp.http.X-Demo-Orig-Response = beresp.response;
      set beresp.status = 503;
      set beresp.response = "Service Unavailable";
      set req.http.X-Orig-Backend  = beresp.backend.name;
      set bereq.http.X-Failover = "1";
      restart;
    }
  }
  else if (beresp.status == 403) {
      set beresp.http.X-Demo-Orig-Status = beresp.status;
      set beresp.http.X-Demo-Orig-Response = beresp.response;
      set beresp.status = 404;
      set beresp.response = "Not Found";
  }

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

  # --- TTL from 'timers' dictionary ---
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
  # --- Set Debug headers ---
  set beresp.http.X-Demo-Resolved-URL = bereq.url;
  set beresp.http.X-Demo-Origin-Host  = bereq.http.Host;
  set beresp.http.X-Demo-Initial-TTL  = var.ttl_cfg;


  # --- END Chris's fetch additions --------->

  # Unset headers that reduce cacheability for images processed using the Fastly image optimizer
  if (req.http.X-Fastly-Imageopto-Api) {
    unset beresp.http.Set-Cookie;
    unset beresp.http.Vary;
  }

  # Log the number of restarts for debugging purposes
  if (req.restarts > 0) {
    set beresp.http.Fastly-Restarts = req.restarts;
  }

  # If the response is setting a cookie, make sure it is not cached
  if (beresp.http.Set-Cookie) {
    return(pass);
  }

  # By default we set a TTL based on the `Cache-Control` header but we don't parse additional directives
  # like `private` and `no-store`. Private in particular should be respected at the edge:
  if (beresp.http.Cache-Control ~ "(?:private|no-store)") {
    return(pass);
  }

  # If no TTL has been provided in the response headers, set a default
  if (!beresp.http.Expires && !beresp.http.Surrogate-Control ~ "max-age" && !beresp.http.Cache-Control ~ "(?:s-maxage|max-age)") {
    set beresp.ttl = 3600s;

    # Apply a longer default TTL for images processed using Image Optimizer
    if (req.http.X-Fastly-Imageopto-Api) {
      set beresp.ttl = 2592000s; # 30 days
      set beresp.http.Cache-Control = "max-age=2592000, public";
    }
  }

  return(deliver);
}

sub vcl_error {
#FASTLY error
  return(deliver);
}

sub vcl_deliver {
#FASTLY deliver
 declare local var.debug STRING;
  set var.debug = table.lookup(debug_flags, "debug", "off");

  if (var.debug == "on") {
    if (req.http.X-Orig-Backend) {
      set resp.http.X-Demo-Orig-Backend  = req.http.X-Orig-Backend;
    }
    if (req.http.X-Demo-Origin-Region) {
      set resp.http.X-Demo-Origin-Region = req.http.X-Demo-Origin-Region;
    }
    set resp.http.X-Demo-Debug      = "on";
    set resp.http.X-Demo-POP        = server.identity;
    set resp.http.X-Demo-Edge-Cache = if (obj.hits > 0, "HIT", "MISS");
    set resp.http.X-Demo-Orig-URL = "https://" req.http.Host req.url;
    
  } else {
    unset resp.http.X-Demo-Origin-Region;
    unset resp.http.X-Demo-Initial-TTL;
    unset resp.http.X-Demo-Resolved-URL;
    unset resp.http.X-Demo-Origin-Host;
    unset resp.http.X-Demo-Debug;
    unset resp.http.X-Demo-POP;
    unset resp.http.X-Demo-Edge-Cache;
    unset resp.http.X-Demo-Orig-Status;
    unset resp.http.X-Demo-Orig-Response;
    unset resp.http.X-Demo-Orig-Backend;
  }


  return(deliver);
}

sub vcl_log {
#FASTLY log
}