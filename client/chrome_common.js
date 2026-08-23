// chrome_common.js — the shared DOM chrome for every gridlock surface
// (the static replay bundle, the live spectator page and the player page).
//
// Split of responsibilities, inherited from paintbot: the canvas core draws
// the WORLD (asphalt, intersections, signal heads, scenery, congestion heat,
// depots, vans); this file draws the SCOREBUG, the fleet counters, the plan
// chips, the event feed, the jam gauge, the transport and the warnings.
//
// Every piece of text here is set with textContent. Player names are
// player-controlled data and must never reach innerHTML.
//
// TWO NAME SPACES: the board and the seats only ever see the depot aliases
// (Copper / Cobalt / Verde / Saffron). Real policy names appear in the
// scorebug, the endcard and the feed — spectator side only — and nowhere
// else.
(function () {
  'use strict';

  var globalScope = typeof window !== 'undefined' ? window : self;

  function el(id) { return document.getElementById(id); }

  function clear(node) {
    while (node && node.firstChild) node.removeChild(node.firstChild);
  }

  function div(className, text) {
    var node = document.createElement('div');
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  function clock(secondsLeft) {
    var total = Math.max(0, Math.round(secondsLeft));
    var mm = Math.floor(total / 60);
    var ss = total % 60;
    return (mm < 10 ? '0' : '') + mm + ':' + (ss < 10 ? '0' : '') + ss;
  }

  function districtName(index) {
    var names = ['NW', 'N', 'NE', 'W', 'CENTRE', 'E', 'SW', 'S', 'SE'];
    return names[index] || '-';
  }

  function districtIndex(pair) {
    if (!pair || pair.length !== 2) return -1;
    return pair[0] + 3 * pair[1];
  }

  // -----------------------------------------------------------------------
  // Plain-language plan lines. This is where the LLM is visible playing:
  // a spectator sees a strategy change BEFORE the roads change.
  // -----------------------------------------------------------------------
  function planLine(alias, plan) {
    var bits = [];
    bits.push(plan.congestion_weight === 0 ? 'no repricing'
      : 'reprice ' + plan.congestion_weight);
    bits.push('dispatch ' + plan.dispatch);
    if (plan.avoid) bits.push('avoid ' + districtName(districtIndex(plan.avoid)));
    if (plan.corridor) {
      bits.push('via ' + districtName(districtIndex(plan.corridor)));
    }
    bits.push(plan.priority + '-first');
    return alias + ' \u2192 ' + bits.join(', ');
  }

  function eventLine(meta, event) {
    switch (event.type) {
      case 'plan': {
        return planLine(event.fleet, event);
      }
      case 'fallback':
        return meta.aliases[event.seat] + ' falls back (' + event.cause + ')';
      case 'gridlock':
        return 'GRIDLOCK \u2014 ' + event.district_name + ', ' +
          event.blocked_lanes + ' lanes blocked';
      case 'meter':
        return event.held > 0
          ? event.fleet + ' holds ' + event.held + ' vans at the depot'
          : null;
      case 'budget_guard':
        return 'dispatcher budget guard engaged';
      default:
        return null;
    }
  }

  function createChrome(meta) {
    var state = {
      meta: meta,
      feed: [],
      flash: null,
      lastTick: 0,
      lastTurn: -1,
      history: []
    };

    // --- scorebug ------------------------------------------------------
    // ensureScorebug(teams) generates one plate per active fleet for 2-4
    // fleets; gridlock always has four, and the plates split left/right the
    // way the inherited chrome does.
    function ensureScorebug(count) {
      var left = el('plates-l');
      var right = el('plates-r');
      if (!left || !right) return [];
      if (left.childElementCount + right.childElementCount === count) {
        return Array.prototype.slice.call(left.children)
          .concat(Array.prototype.slice.call(right.children));
      }
      clear(left);
      clear(right);
      var plates = [];
      for (var i = 0; i < count; i++) {
        var plate = div('plate');
        var chip = div('chip');
        chip.style.background = meta.colours[i] || '#888';
        var name = div('team-name plate-name', meta.players[i] || ('P' + i));
        var alias = div('team-alias', meta.aliases[i] || '');
        var score = div('team-score', '0');
        plate.appendChild(chip);
        plate.appendChild(name);
        plate.appendChild(alias);
        plate.appendChild(score);
        (i % 2 === 0 ? left : right).appendChild(plate);
        plates.push(plate);
      }
      return plates;
    }

    function ensureFleetbug() {
      var bug = el('fleetbug');
      if (!bug || bug.childElementCount === 4) return;
      clear(bug);
      for (var i = 0; i < 4; i++) {
        var cell = div('fleet-counter corner-' + i);
        var dot = div('fleet-dot');
        dot.style.background = meta.colours[i] || '#888';
        var alias = div('fleet-alias', meta.aliases[i] || '');
        var count = div('fleet-count', '0');
        var bar = div('fleet-bar');
        bar.appendChild(div('fleet-bar-fill'));
        cell.appendChild(dot);
        cell.appendChild(alias);
        cell.appendChild(count);
        cell.appendChild(bar);
        bug.appendChild(cell);
      }
    }

    function ensurePlanbar() {
      var bar = el('planbar');
      if (!bar || bar.childElementCount === 4) return;
      clear(bar);
      for (var i = 0; i < 4; i++) {
        var chip = div('plan-chip');
        var dot = div('plan-dot');
        dot.style.background = meta.colours[i] || '#888';
        chip.appendChild(dot);
        chip.appendChild(div('plan-text', '\u2014'));
        bar.appendChild(chip);
      }
    }

    function ensureJamgauge() {
      var gauge = el('jamgauge');
      if (!gauge || gauge.childElementCount) return;
      gauge.appendChild(div('jam-label', 'JAM'));
      var track = div('jam-track');
      track.appendChild(div('jam-fill'));
      gauge.appendChild(track);
      gauge.appendChild(div('jam-value', '0'));
      var grid = div('jam-grid');
      for (var i = 0; i < 9; i++) grid.appendChild(div('jam-cell', '0'));
      gauge.appendChild(grid);
    }

    function pushFeed(line) {
      if (!line) return;
      state.feed.push(line);
      while (state.feed.length > 6) state.feed.shift();
    }

    function paintFeed() {
      var feed = el('killfeed');
      if (!feed) return;
      clear(feed);
      for (var i = 0; i < state.feed.length; i++) {
        feed.appendChild(div('feed-line', state.feed[i]));
      }
    }

    function paintEndcard(frame) {
      var card = el('endcard');
      if (!card) return;
      var results = meta.results || {};
      if (!results.reason) return;
      var headline = el('ec-headline');
      var winner = results.winner;
      if (headline) {
        headline.textContent = (winner === null || winner === undefined)
          ? 'No winner \u2014 ' + (results.total_delivered || 0) +
            ' parcels delivered'
          : (meta.aliases[winner] || '?') + ' wins \u2014 ' +
            (results.delivered ? results.delivered[winner] : 0) + ' parcels';
      }
      var wincond = el('ec-wincond');
      if (wincond) {
        wincond.textContent = 'Most parcels delivered wins. Score is your own ' +
          'deliveries \u2014 not a share, so the total is destructible.';
      }
      var how = el('ec-how');
      if (how) {
        var stalled = 0;
        var seconds = results.stalled_vehicle_seconds || [];
        for (var s = 0; s < seconds.length; s++) stalled += seconds[s];
        how.textContent = (results.total_delivered || 0) +
          ' parcels delivered \u00b7 mean jam ' + (results.jam_index_mean || 0) +
          ' \u00b7 peak ' + (results.jam_index_peak || 0) + ' \u00b7 ' +
          (results.gridlock_events || 0) + ' gridlocks \u2014 the city lost an ' +
          'estimated ' + Math.round(stalled / 60) +
          ' minutes of van time to queues';
      }
      var teams = el('ec-teams');
      if (teams) {
        clear(teams);
        for (var i = 0; i < 4; i++) {
          var row = div('ec-row');
          var chip = div('chip');
          chip.style.background = meta.colours[i] || '#888';
          row.appendChild(chip);
          row.appendChild(div('ec-name', meta.players[i] + ' \u00b7 ' +
            meta.aliases[i]));
          row.appendChild(div('ec-num',
            (results.delivered ? results.delivered[i] : 0) + ' parcels'));
          row.appendChild(div('ec-num', 'trip ' +
            (results.mean_trip_seconds ? results.mean_trip_seconds[i] : 0) +
            's'));
          row.appendChild(div('ec-num', 'stalled ' +
            Math.round((results.stalled_vehicle_seconds
              ? results.stalled_vehicle_seconds[i] : 0) / 60) + ' min'));
          row.appendChild(div('ec-num', 'backlog ' +
            (results.backlog_final ? results.backlog_final[i] : 0)));
          teams.appendChild(row);
        }
      }
      if (frame && frame.t >= (meta.tick_count || 0) - 1) {
        card.classList.add('show');
      }
    }

    function applyFrame(frame) {
      ensureFleetbug();
      ensurePlanbar();
      ensureJamgauge();
      var plates = ensureScorebug(4);
      var leader = 0;
      for (var i = 1; i < 4; i++) {
        if (frame.delivered[i] > frame.delivered[leader]) leader = i;
      }
      for (var p = 0; p < plates.length; p++) {
        var score = plates[p].querySelector('.team-score');
        if (score) score.textContent = String(frame.delivered[p]);
        plates[p].classList.toggle('leader', p === leader);
      }
      var bug = el('fleetbug');
      if (bug) {
        for (var f = 0; f < bug.childElementCount; f++) {
          var cell = bug.children[f];
          var count = cell.querySelector('.fleet-count');
          if (count) count.textContent = String(frame.delivered[f]);
          var fill = cell.querySelector('.fleet-bar-fill');
          if (fill) {
            fill.style.width =
              Math.round(100 * frame.on_road[f] /
                Math.max(1, meta.vans_per_fleet)) + '%';
            fill.style.background = meta.colours[f] || '#888';
          }
        }
      }
      var bar = el('planbar');
      if (bar && frame.plans) {
        for (var q = 0; q < bar.childElementCount; q++) {
          var text = bar.children[q].querySelector('.plan-text');
          if (text) {
            text.textContent = frame.plans[q].congestion_weight + ' / ' +
              frame.plans[q].dispatch;
          }
        }
      }
      var gauge = el('jamgauge');
      if (gauge) {
        var fill2 = gauge.querySelector('.jam-fill');
        if (fill2) {
          fill2.style.width = Math.max(2, frame.jam) + '%';
          fill2.style.background = frame.jam > 70 ? '#c2452d'
            : (frame.jam > 45 ? '#d9a441' : '#4d7c4f');
        }
        var value = gauge.querySelector('.jam-value');
        if (value) value.textContent = String(frame.jam);
        var cells = gauge.querySelectorAll('.jam-cell');
        for (var c = 0; c < cells.length && c < frame.digits.length; c++) {
          cells[c].textContent = String(frame.digits[c]);
          cells[c].className = 'jam-cell heat-' + Math.min(9, frame.digits[c]);
        }
      }
      var clockTime = el('clock-time');
      if (clockTime) {
        var left = Math.max(0, (meta.tick_count - frame.t) /
          (meta.ticks_per_second || 24));
        clockTime.textContent = clock(left);
      }
      var caption = el('clock-caption');
      if (caption) {
        caption.textContent = 'turn ' + frame.turn + '/' +
          Math.max(1, Math.round(meta.tick_count / meta.turn_ticks));
      }
      var tickClock = el('tick-clock');
      if (tickClock) tickClock.textContent = 't ' + frame.t;
      var scrubFill = el('scrub-fill');
      if (scrubFill) {
        scrubFill.style.width =
          Math.min(100, 100 * frame.t / Math.max(1, meta.tick_count)) + '%';
      }
      var head = el('scrub-head');
      if (head) {
        head.style.left =
          Math.min(100, 100 * frame.t / Math.max(1, meta.tick_count)) + '%';
      }
      if (frame.events) {
        for (var e = 0; e < frame.events.length; e++) {
          var line = eventLine(meta, frame.events[e]);
          if (line) pushFeed(line);
          if (frame.events[e].type === 'plan' && frame.events[e].say) {
            pushFeed(frame.events[e].fleet + ' says "' +
              frame.events[e].say + '"');
          }
          if (frame.events[e].type === 'gridlock') {
            var flash = el('jamflash');
            if (flash) {
              flash.classList.add('show');
              globalScope.setTimeout(function () {
                flash.classList.remove('show');
              }, 2200);
            }
            var banner = el('bannerlane');
            if (banner) {
              banner.textContent = 'GRIDLOCK \u2014 ' +
                frame.events[e].district_name + ', ' +
                frame.events[e].blocked_lanes + ' lanes blocked';
              banner.classList.add('show');
              globalScope.setTimeout(function () {
                banner.classList.remove('show');
              }, 2200);
            }
          }
        }
        paintFeed();
      }
      state.lastTick = frame.t;
      paintEndcard(frame);
    }

    return {
      applyFrame: applyFrame,
      pushFeed: function (line) { pushFeed(line); paintFeed(); },
      meta: meta
    };
  }

  // -----------------------------------------------------------------------
  // Page boot. Runs on `load` in a Window only (the Worker never imports this
  // file). It owns the --hudscale relayout loop, the transport, the speed
  // chips and the scrubber, and it hands the canvas to whichever core is
  // present: GridlockStaticReplay in the static bundle, BroadcastCore
  // in-process on the live spectator page.
  // -----------------------------------------------------------------------
  function relayout() {
    var board = el('board');
    if (!board) return;
    var w = board.getBoundingClientRect().width || 760;
    var scale = Math.max(0.5, Math.min(1.6, w / 760));
    document.documentElement.style.setProperty('--hudscale', String(scale));
    document.body.classList.toggle('tiny', w < 420);
  }

  function boot() {
    var board = el('board');
    if (!board || !globalScope.GridlockStaticReplay) return;
    relayout();
    globalScope.addEventListener('resize', relayout);

    var chrome = null;
    var meta = null;
    var lastTick = 0;
    var looping = false;
    var speeds = [1, 2, 3, 4, 8, 16];
    var core = globalScope.GridlockStaticReplay.createCore({
      canvas: board,
      onText: function (text) {
        var payload;
        try { payload = JSON.parse(text); } catch (ignore) { return; }
        if (payload.type === 'meta') {
          meta = payload;
          if (payload.playback_speeds) speeds = payload.playback_speeds;
          chrome = createChrome(payload);
          buildSpeedChips();
        } else if (chrome) {
          lastTick = payload.t || 0;
          chrome.applyFrame(payload);
          if (looping && meta && lastTick >= meta.tick_count - 1) {
            core.seek(0);
          }
        }
      },
      onStatus: function (status) {
        var chip = el('status');
        if (chip && status === 'error') chip.classList.add('show');
      }
    });

    function buildSpeedChips() {
      var host = el('speedchips');
      if (!host) return;
      clear(host);
      speeds.forEach(function (value) {
        var chip = div('speedchip', value + '\u00d7');
        if (value === core.getSpeed()) chip.classList.add('on');
        chip.onclick = function () {
          core.setSpeed(value);
          var chips = host.querySelectorAll('.speedchip');
          for (var i = 0; i < chips.length; i++) {
            chips[i].classList.toggle('on', chips[i] === chip);
          }
        };
        host.appendChild(chip);
      });
    }

    function seekFraction(fraction) {
      if (!meta) return;
      core.seek(Math.round(fraction * meta.tick_count));
    }

    var scrub = el('scrub');
    if (scrub) {
      scrub.addEventListener('click', function (event) {
        var box = scrub.getBoundingClientRect();
        if (!box.width) return;
        seekFraction(Math.max(0, Math.min(1,
          (event.clientX - box.left) / box.width)));
      });
    }
    var play = el('btn-play');
    if (play) {
      play.onclick = function () {
        core.setPlaying(!core.isPlaying());
        play.textContent = core.isPlaying() ? '\u275a\u275a' : '\u25b6';
      };
    }
    var restart = el('btn-restart');
    if (restart) restart.onclick = function () { seekFraction(0); };
    var toEnd = el('btn-end');
    if (toEnd) toEnd.onclick = function () { seekFraction(1); };
    // Back one tick and forward five seconds, the inherited transport's own
    // meanings. #btn-restart is the seek to zero.
    var back = el('btn-back');
    if (back) {
      back.onclick = function () { core.seek(Math.max(0, lastTick - 1)); };
    }
    var fwd = el('btn-fwd');
    if (fwd) {
      fwd.onclick = function () {
        if (!meta) return;
        var step = 5 * (meta.ticks_per_second || 24);
        core.seek(Math.min(meta.tick_count - 1, lastTick + step));
      };
    }
    // LOOP restarts the match when playback reaches the end. The two other
    // inherited buttons in this row (#btn-skip, #btn-spoilers) drive the
    // lull-span machinery, which gridlock does not ship: they are hidden in
    // the page's CSS rather than left sitting there doing nothing.
    var loop = el('btn-loop');
    if (loop) {
      loop.onclick = function () {
        looping = !looping;
        loop.classList.toggle('on', looping);
      };
    }
    // No zoom bar and no minimap: the whole district grid fits the stage,
    // so there is nothing a zoomed view would show that the board does not.
    globalScope.addEventListener('resize', core.setViewportFit);
    buildSpeedChips();
    core.start();
  }

  globalScope.ChromeCommon = {
    createChrome: createChrome,
    districtName: districtName,
    planLine: planLine,
    clock: clock,
    boot: boot,
    relayout: relayout
  };

  if (typeof document !== 'undefined') {
    globalScope.addEventListener('load', boot);
  }
})();
