// broadcast_core.js — gridlock's world renderer.
//
// Dependency-free IIFE. It runs in a Dedicated Worker against an
// OffscreenCanvas (the shipped static bundle) and, unchanged, in a Window
// against a normal canvas (the live spectator page). Keep ONE implementation
// so a rendering fix cannot drift between the two delivery modes — that rule
// is inherited from paintbot's core of the same name.
//
// It draws the WORLD only: asphalt, painted city blocks, the congestion heat
// ramp over all 288 lanes, intersections with their signal heads, the four
// depots, and 200 vans. The DOM chrome (scorebug, fleet counters, plan chips,
// feed, jam gauge, transport) lives in chrome_common.js and is fed through
// onText.
//
// THE PICTURE THE GAME IS ABOUT: every lane is a bar coloured by occupancy,
// drawn UNDER the vans and OVER the asphalt, so a jam is literally a stain
// crawling backwards out of an intersection.
(function () {
  'use strict';

  var scope = typeof window !== 'undefined' ? window : self;
  var raf = typeof scope.requestAnimationFrame === 'function'
    ? scope.requestAnimationFrame.bind(scope)
    : function (cb) { return setTimeout(function () { cb(Date.now()); }, 16); };

  var HEAT = ['#3b424c', '#3d5a44', '#4d7c4f', '#4d7c4f', '#6d8c45',
    '#8f9442', '#b39a41', '#d9a441', '#d08038', '#c2452d', '#c2452d',
    '#a5331f', '#8e2318', '#7a1414', '#7a1414'];

  var ART = ['asphalt.jpg', 'intersection.png', 'block_park.png',
    'block_roof.png', 'plaza.png', 'depot_copper.png', 'depot_cobalt.png',
    'depot_verde.png', 'depot_saffron.png', 'van.png', 'van_loaded.png',
    'parcel_pin.png'];

  function makeSurface(w, h) {
    if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(w, h);
    var canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    return canvas;
  }

  // Pre-tinting is done ONCE per fleet at load: per-draw tinting of 200 vans
  // a frame would cost a composite per van. Only the cart body takes the
  // depot colour: the sprite is a nano-banana render of a Softmax cog driving
  // a deliberately unpainted grey cart, so low-saturation pixels are cart and
  // everything else (the cog, the parcels, the dark outlines) is left alone.
  var VAN_PX = 22;
  function tinted(bitmap, colour) {
    var surface = makeSurface(bitmap.width, bitmap.height);
    var ctx = surface.getContext('2d');
    ctx.drawImage(bitmap, 0, 0);
    var rgb = hexRgb(colour);
    if (!rgb) return surface;
    var image;
    try { image = ctx.getImageData(0, 0, bitmap.width, bitmap.height); }
    catch (ignore) { return surface; }
    var d = image.data;
    for (var i = 0; i < d.length; i += 4) {
      if (!d[i + 3]) continue;
      var r = d[i], g = d[i + 1], b = d[i + 2];
      var hi = Math.max(r, g, b), lo = Math.min(r, g, b);
      if (hi - lo > 28 || hi < 90) continue;  // coloured or outline: keep
      var lum = hi / 215;                    // cart grey peaks ~#d6d6d6
      d[i] = Math.min(255, rgb[0] * lum);
      d[i + 1] = Math.min(255, rgb[1] * lum);
      d[i + 2] = Math.min(255, rgb[2] * lum);
    }
    ctx.putImageData(image, 0, 0);
    return surface;
  }

  function hexRgb(colour) {
    var m = /^#([0-9a-f]{6})$/i.exec(String(colour || ''));
    if (!m) return null;
    var n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }

  function create(config) {
    var canvas = config.canvas;
    var ctx = canvas.getContext('2d', { alpha: false });
    var meta = null;
    var frame = null;
    var art = {};
    var vans = { plain: [], loaded: [] };
    var asphaltPattern = null;
    var viewport = {
      width: config.viewportWidth || 800,
      height: config.viewportHeight || 800,
      dpr: config.devicePixelRatio || 1
    };
    var transform = {
      scale: 1, offsetX: 0, offsetY: 0, nativeW: 1024, nativeH: 1024,
      zoom: 1, minZoom: 1, maxZoom: 8, fitScale: 1,
      focusX: 512, focusY: 512, visW: 1024, visH: 1024
    };
    var zoom = 1;
    var focus = { x: 512, y: 512 };
    var minimap = null;
    var draws = 0;
    var running = false;
    var firstFrameSent = false;
    var flash = null;

    function status(text) { if (config.onStatus) config.onStatus(text); }

    function loadArt() {
      var base = scope.location && scope.location.href
        ? scope.location.href : './';
      ART.forEach(function (name) {
        var url;
        try { url = new URL('./art/' + name, base).toString(); }
        catch (ignore) { url = './art/' + name; }
        // Art is decoration: a miss must never stop a frame from being drawn,
        // so nothing here is awaited and every failure is swallowed.
        fetch(url).then(function (response) {
          if (!response.ok) throw new Error(String(response.status));
          return response.blob();
        }).then(function (blob) {
          return createImageBitmap(blob);
        }).then(function (bitmap) {
          art[name] = bitmap;
          if (name === 'asphalt.jpg') {
            try { asphaltPattern = ctx.createPattern(bitmap, 'repeat'); }
            catch (ignore) { asphaltPattern = null; }
          }
          if (name === 'van.png' || name === 'van_loaded.png') {
            rebuildVans();
          }
        }).catch(function () { /* painted fallbacks below */ });
      });
    }

    function rebuildVans() {
      if (!meta) return;
      if (art['van.png']) {
        vans.plain = meta.colours.map(function (c) {
          return tinted(art['van.png'], c);
        });
      }
      if (art['van_loaded.png']) {
        vans.loaded = meta.colours.map(function (c) {
          return tinted(art['van_loaded.png'], c);
        });
      }
    }

    function resize() {
      var w = Math.max(1, Math.round(viewport.width * viewport.dpr));
      var h = Math.max(1, Math.round(viewport.height * viewport.dpr));
      if (canvas.width !== w) canvas.width = w;
      if (canvas.height !== h) canvas.height = h;
      var board = meta ? meta.board[0] : 1024;
      transform.nativeW = board;
      transform.nativeH = meta ? meta.board[1] : 1024;
      transform.fitScale = Math.min(w / transform.nativeW,
        h / transform.nativeH);
      transform.scale = transform.fitScale * zoom;
      transform.zoom = zoom;
      transform.offsetX = w / 2 - focus.x * transform.scale;
      transform.offsetY = h / 2 - focus.y * transform.scale;
      transform.focusX = focus.x;
      transform.focusY = focus.y;
      transform.visW = w / transform.scale;
      transform.visH = h / transform.scale;
      if (config.onTransform) config.onTransform(transform);
    }

    function nodePixel(index) {
      var ix = index % meta.grid[0];
      var iy = Math.floor(index / meta.grid[0]);
      return [meta.margin + meta.spacing * ix, meta.margin + meta.spacing * iy];
    }

    function drawBackground() {
      ctx.fillStyle = '#191c21';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.save();
      ctx.setTransform(transform.scale, 0, 0, transform.scale,
        transform.offsetX, transform.offsetY);
      if (asphaltPattern) {
        ctx.fillStyle = asphaltPattern;
      } else {
        ctx.fillStyle = '#343a42';
      }
      ctx.fillRect(0, 0, transform.nativeW, transform.nativeH);
      ctx.strokeStyle = '#0f1216';
      ctx.lineWidth = 6;
      ctx.strokeRect(0, 0, transform.nativeW, transform.nativeH);
    }

    function drawScenery() {
      var pieces = meta.scenery || [];
      for (var i = 0; i < pieces.length; i++) {
        var piece = pieces[i];
        var bitmap = art[piece.art + '.png'];
        if (piece.kind === 'disc') {
          if (bitmap) {
            ctx.drawImage(bitmap, piece.cx - piece.r, piece.cy - piece.r,
              piece.r * 2, piece.r * 2);
          } else {
            ctx.fillStyle = '#6f6b62';
            ctx.beginPath();
            ctx.arc(piece.cx, piece.cy, piece.r, 0, Math.PI * 2);
            ctx.fill();
          }
        } else if (bitmap) {
          ctx.drawImage(bitmap, piece.x, piece.y, piece.w, piece.h);
        } else {
          ctx.fillStyle = piece.art === 'block_park' ? '#3a4a3a' : '#484650';
          ctx.fillRect(piece.x, piece.y, piece.w, piece.h);
        }
      }
    }

    function drawLanes() {
      var lanes = meta.lanes;
      var cap = meta.lane_cells;
      var offset = meta.lane_offset;
      var width = Math.max(2 / Math.max(0.001, transform.scale), 6);
      ctx.lineCap = 'round';
      for (var i = 0; i < lanes.length; i++) {
        var q = frame.q[i] || 0;
        var lane = lanes[i];
        var dx = lane.b[0] - lane.a[0];
        var dy = lane.b[1] - lane.a[1];
        var len = Math.abs(dx) + Math.abs(dy);
        if (len === 0) continue;
        var ux = dx / len;
        var uy = dy / len;
        var rx = -uy * offset;
        var ry = ux * offset;
        ctx.strokeStyle = HEAT[Math.min(HEAT.length - 1, q)];
        ctx.globalAlpha = q === 0 ? 0.72 : 0.96;
        ctx.lineWidth = width;
        ctx.beginPath();
        ctx.moveTo(lane.a[0] + rx, lane.a[1] + ry);
        ctx.lineTo(lane.b[0] + rx, lane.b[1] + ry);
        ctx.stroke();
        if (q >= cap) {
          ctx.globalAlpha = 0.35 + 0.35 *
            Math.abs(Math.sin(frame.t * 0.12));
          ctx.strokeStyle = '#ff4d33';
          ctx.lineWidth = width * 1.6;
          ctx.beginPath();
          ctx.moveTo(lane.a[0] + rx, lane.a[1] + ry);
          ctx.lineTo(lane.b[0] + rx, lane.b[1] + ry);
          ctx.stroke();
        }
      }
      ctx.globalAlpha = 1;
    }

    function drawIntersections() {
      var cols = meta.grid[0];
      var rows = meta.grid[1];
      var box = art['intersection.png'];
      var cycle = 96;
      for (var iy = 0; iy < rows; iy++) {
        for (var ix = 0; ix < cols; ix++) {
          var x = meta.margin + meta.spacing * ix;
          var y = meta.margin + meta.spacing * iy;
          if (box) {
            ctx.drawImage(box, x - 12, y - 12, 24, 24);
          } else {
            ctx.fillStyle = '#3c424a';
            ctx.fillRect(x - 8, y - 8, 16, 16);
          }
          var offsetTicks = ((ix + iy) % 4) * 24;
          var ns = ((frame.t + offsetTicks) % cycle) < 48;
          ctx.fillStyle = ns ? '#67d17a' : '#22262c';
          ctx.fillRect(x - 1.5, y - 11, 3, 3);
          ctx.fillRect(x - 1.5, y + 8, 3, 3);
          ctx.fillStyle = ns ? '#22262c' : '#67d17a';
          ctx.fillRect(x - 11, y - 1.5, 3, 3);
          ctx.fillRect(x + 8, y - 1.5, 3, 3);
        }
      }
    }

    function drawDepots() {
      for (var i = 0; i < meta.depots.length; i++) {
        var depot = meta.depots[i];
        var key = 'depot_' + depot.alias.toLowerCase() + '.png';
        var bitmap = art[key];
        if (bitmap) {
          ctx.drawImage(bitmap, depot.px[0] - 22, depot.px[1] - 22, 44, 44);
        } else {
          ctx.fillStyle = depot.colour;
          ctx.fillRect(depot.px[0] - 16, depot.px[1] - 16, 32, 32);
        }
        ctx.fillStyle = 'rgba(12,14,18,0.72)';
        ctx.fillRect(depot.px[0] - 30, depot.px[1] + 22, 60, 15);
        ctx.fillStyle = depot.colour;
        ctx.font = '12px sans-serif';
        ctx.textAlign = 'center';
        ctx.fillText(depot.alias, depot.px[0], depot.px[1] + 33);
      }
    }

    function drawVans() {
      var lanes = meta.lanes;
      var cellPx = meta.cell_px;
      var offset = meta.lane_offset;
      var perFleet = meta.vans_per_fleet;
      for (var g = 0; g < frame.v.length / 3; g++) {
        var lane = frame.v[g * 3];
        if (lane === 65535) continue;
        var cell = frame.v[g * 3 + 1];
        var stateCode = frame.v[g * 3 + 2];
        var seat = Math.floor(g / perFleet);
        var entry = lanes[lane];
        if (!entry) continue;
        var dx = entry.b[0] - entry.a[0];
        var dy = entry.b[1] - entry.a[1];
        var len = Math.abs(dx) + Math.abs(dy);
        if (len === 0) continue;
        var ux = dx / len;
        var uy = dy / len;
        var along = (cell * 2 + 1) * cellPx / 2;
        var x = entry.a[0] + ux * along - uy * offset;
        var y = entry.a[1] + uy * along + ux * offset;
        if (stateCode === 3) {
          ctx.strokeStyle = 'rgba(255,80,60,0.9)';
          ctx.lineWidth = 1.2;
          ctx.beginPath();
          ctx.arc(x, y, 5.5, 0, Math.PI * 2);
          ctx.stroke();
        }
        var sprite = stateCode === 1
          ? vans.loaded[seat] : vans.plain[seat];
        if (sprite) {
          // the cart is a side view facing right: flip for westbound lanes,
          // rotate for north/south, and sit its wheels just below the cell
          ctx.save();
          ctx.translate(x, y);
          var fx = ux, fy = uy;
          if (fx < 0) { ctx.scale(-1, 1); fx = -fx; }
          ctx.rotate(Math.atan2(fy, fx));
          ctx.drawImage(sprite, -VAN_PX / 2, -VAN_PX * 0.6, VAN_PX, VAN_PX);
          ctx.restore();
        } else {
          ctx.fillStyle = meta.colours[seat] || '#ddd';
          ctx.fillRect(x - 3, y - 3, 6, 6);
          if (stateCode === 1) {
            ctx.fillStyle = '#f4f4ef';
            ctx.fillRect(x - 1, y - 1, 2, 2);
          }
        }
      }
    }

    function drawFlash() {
      if (!flash || flash.ticks <= 0) return;
      flash.ticks -= 1;
      var bx = flash.district % 3;
      var by = Math.floor(flash.district / 3);
      var x0 = meta.margin + meta.spacing * (bx * 3) - meta.spacing / 2;
      var y0 = meta.margin + meta.spacing * (by * 3) - meta.spacing / 2;
      ctx.fillStyle = 'rgba(194,69,45,0.18)';
      ctx.fillRect(x0, y0, meta.spacing * 3, meta.spacing * 3);
      ctx.strokeStyle = 'rgba(255,90,60,0.8)';
      ctx.lineWidth = 3;
      ctx.strokeRect(x0, y0, meta.spacing * 3, meta.spacing * 3);
    }

    function drawMinimap() {
      if (!minimap) return;
      var mctx = minimap.getContext('2d');
      var w = minimap.width || 120;
      var h = minimap.height || 120;
      mctx.fillStyle = '#14171c';
      mctx.fillRect(0, 0, w, h);
      var s = Math.min(w, h) / transform.nativeW;
      for (var i = 0; i < meta.lanes.length; i++) {
        var q = frame.q[i] || 0;
        if (q === 0) continue;
        var lane = meta.lanes[i];
        mctx.strokeStyle = HEAT[Math.min(HEAT.length - 1, q)];
        mctx.lineWidth = 1.5;
        mctx.beginPath();
        mctx.moveTo(lane.a[0] * s, lane.a[1] * s);
        mctx.lineTo(lane.b[0] * s, lane.b[1] * s);
        mctx.stroke();
      }
    }

    function draw() {
      if (!meta || !frame) return;
      resize();
      drawBackground();
      drawScenery();
      drawLanes();
      drawIntersections();
      drawDepots();
      drawVans();
      drawFlash();
      ctx.restore();
      drawMinimap();
      draws += 1;
      if (!firstFrameSent) {
        firstFrameSent = true;
        if (config.onFirstFrame) config.onFirstFrame();
      }
    }

    function chromeText() {
      return JSON.stringify({
        type: 'frame',
        t: frame.t,
        turn: frame.turn,
        jam: frame.jam,
        digits: frame.digits,
        delivered: frame.delivered,
        on_road: frame.on_road,
        backlog: frame.backlog,
        plans: frame.plans,
        events: frame.events
      });
    }

    function ingest(payload) {
      var message = typeof payload === 'string' ? JSON.parse(payload) : payload;
      if (!message) return;
      if (message.type === 'meta') {
        meta = message;
        zoom = 1;
        focus.x = meta.board[0] / 2;
        focus.y = meta.board[1] / 2;
        rebuildVans();
        status('ready');
        // The page needs the names, aliases, colours and results to build the
        // scorebug and the endcard; the canvas needs the geometry. One
        // channel, two consumers.
        if (config.onText) {
          config.onText(JSON.stringify({
            type: 'meta',
            players: meta.players,
            aliases: meta.aliases,
            colours: meta.colours,
            policy_kinds: meta.policy_kinds,
            depots: meta.depots,
            tick_count: meta.tick_count,
            turn_ticks: meta.turn_ticks,
            ticks_per_second: meta.ticks_per_second,
            vans_per_fleet: meta.vans_per_fleet,
            playback_speeds: meta.playback_speeds,
            results: meta.results
          }));
        }
        return;
      }
      frame = message;
      if (frame.events) {
        for (var i = 0; i < frame.events.length; i++) {
          if (frame.events[i].type === 'gridlock') {
            var d = frame.events[i].district;
            flash = { district: d[0] + 3 * d[1], ticks: 48 };
          }
        }
      }
      draw();
      if (config.onText) config.onText(chromeText());
    }

    loadArt();

    return {
      ingest: ingest,
      start: function () { running = true; status('connecting'); },
      stop: function () { running = false; },
      setViewportSize: function (w, h, dpr) {
        viewport.width = w || viewport.width;
        viewport.height = h || viewport.height;
        viewport.dpr = dpr || viewport.dpr;
        if (meta && frame) draw();
      },
      attachMinimap: function (surface) { minimap = surface; },
      getPaceStats: function () {
        return { enabled: running, queued: 0, presented: draws,
          interval: 1000 / 24, draws: draws };
      },
      getTransform: function () { return transform; },
      zoomAt: function (factor) {
        zoom = Math.max(1, Math.min(8, zoom * (factor || 1)));
        if (meta && frame) draw();
      },
      setZoom: function (level) {
        zoom = Math.max(1, Math.min(8, level || 1));
        if (meta && frame) draw();
      },
      panBy: function (dx, dy) {
        focus.x -= (dx || 0) / transform.scale;
        focus.y -= (dy || 0) / transform.scale;
        if (meta && frame) draw();
      },
      panByMap: function (dx, dy) {
        focus.x -= dx || 0;
        focus.y -= dy || 0;
        if (meta && frame) draw();
      },
      panTo: function (x, y) {
        focus.x = x; focus.y = y;
        if (meta && frame) draw();
      },
      resetView: function () {
        zoom = 1;
        if (meta) { focus.x = meta.board[0] / 2; focus.y = meta.board[1] / 2; }
        if (meta && frame) draw();
      },
      sendCommand: function () { /* gridlock has no in-band viewer commands */ },
      clickMap: function () { /* the board has no click targets */ }
    };
  }

  scope.BroadcastCore = { create: create };
})();
