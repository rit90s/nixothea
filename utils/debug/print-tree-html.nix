# Self-contained, interactive HTML rendering of one target's dependency
# tree as a real node-link graph -- inline CSS and inline JS only, no
# external libraries/CDN. Layout is a small hand-rolled force-directed
# simulation (not precomputed, since the visible node set changes
# whenever a filter is applied -- precomputing every possible filtered
# layout doesn't scale, see utils/debug/print-tree.nix's own header for
# the fuller reasoning). Two combinable filters: a name filter (removes
# non-matching boxes from the simulation entirely) and an ancestry filter
# (click a box to select it; shows only its ancestor/descendant/both
# chain, up to an optional max depth). The root is pinned at top-center
# only while no ancestry filter is active -- a diamond means "depth
# relative to root" isn't well-defined once you're looking at an
# arbitrary filtered subgraph, so that pin is dropped entirely rather
# than guessing a different anchor.
{ targetName, graphData }:
''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>nixothea dependency tree: ${targetName}</title>
<style>
  * { box-sizing: border-box; }
  html, body {
    margin: 0;
    padding: 0;
    height: 100%;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: #fafafa;
    color: #222;
  }
  #controls {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 16px;
    padding: 10px 14px;
    background: #fff;
    border-bottom: 1px solid #ddd;
    font-size: 13px;
  }
  #controls h1 {
    font-size: 14px;
    margin: 0;
    font-weight: 600;
  }
  #controls label { margin-right: 4px; }
  #controls input[type="text"], #controls input[type="number"] {
    font-size: 13px;
    padding: 3px 6px;
    border: 1px solid #ccc;
    border-radius: 4px;
  }
  #controls input[type="number"] { width: 60px; }
  #ancestry-panel {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 10px;
    border: 1px solid #ddd;
    border-radius: 6px;
    background: #f5f5f5;
  }
  #ancestry-status { color: #666; }
  #canvas {
    position: relative;
    width: 100%;
    height: calc(100% - 48px);
    overflow: hidden;
    background:
      linear-gradient(90deg, #f0f0f0 1px, transparent 1px),
      linear-gradient(#f0f0f0 1px, transparent 1px);
    background-size: 24px 24px;
  }
  svg#edges {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    pointer-events: none;
  }
  .edge { stroke: #999; stroke-width: 1.5; marker-end: url(#arrowhead); }
  .box {
    position: absolute;
    top: 0;
    left: 0;
    min-width: 90px;
    max-width: 160px;
    padding: 6px 8px;
    border-radius: 6px;
    font-size: 11px;
    line-height: 1.4;
    text-align: center;
    cursor: pointer;
    user-select: none;
    box-shadow: 0 1px 3px rgba(0,0,0,0.15);
  }
  .box.node { background: #cfe3ff; border: 1px solid #4a7fd6; }
  .box.dependency { background: #d8f5d3; border: 1px solid #4caf50; }
  .box.root { border-width: 3px; }
  .box.selected { outline: 3px solid #ff9800; outline-offset: 1px; }
  .box.hidden, .edge.hidden { display: none; }
  .box .label { font-weight: 600; }
  .box .meta { color: #444; }
</style>
</head>
<body>
<div id="controls">
  <h1>${targetName}</h1>
  <div>
    <label for="name-filter">Name filter</label>
    <input id="name-filter" type="text" placeholder="e.g. zlib">
  </div>
  <div id="ancestry-panel">
    <span id="ancestry-status">no node selected</span>
    <label><input type="radio" name="direction" value="ancestors"> ancestors</label>
    <label><input type="radio" name="direction" value="descendants"> descendants</label>
    <label><input type="radio" name="direction" value="both" checked> both</label>
    <label for="max-depth">max depth</label>
    <input id="max-depth" type="number" min="1" placeholder="unlimited">
    <button id="clear-selection">clear</button>
  </div>
</div>
<div id="canvas">
  <svg id="edges">
    <defs>
      <marker id="arrowhead" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto">
        <path d="M0,0 L8,4 L0,8 z" fill="#999"></path>
      </marker>
    </defs>
    <g id="edge-group"></g>
  </svg>
</div>
<script>
(function () {
  "use strict";

  var GRAPH = ${builtins.toJSON graphData};

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  var canvas = document.getElementById("canvas");
  var edgeGroup = document.getElementById("edge-group");

  var nodesById = {};
  GRAPH.nodes.forEach(function (n) {
    nodesById[n.id] = {
      id: n.id,
      kind: n.kind,
      label: n.label,
      version: n.version,
      realName: n.realName,
      x: canvas.clientWidth / 2 + (Math.random() - 0.5) * 200,
      y: canvas.clientHeight / 2 + (Math.random() - 0.5) * 200,
      vx: 0,
      vy: 0
    };
  });

  var outgoing = {};
  var incoming = {};
  Object.keys(nodesById).forEach(function (id) {
    outgoing[id] = [];
    incoming[id] = [];
  });
  var edgesList = GRAPH.edges.map(function (e) {
    outgoing[e.from].push(e.to);
    incoming[e.to].push(e.from);
    return { from: e.from, to: e.to };
  });

  // DOM: one box per node, one <line> per edge.
  Object.keys(nodesById).forEach(function (id) {
    var n = nodesById[id];
    var el = document.createElement("div");
    el.className = "box " + n.kind + (id === GRAPH.rootId ? " root" : "");
    var lines = [ "<div class=\"label\">" + escapeHtml(n.label) + "</div>" ];
    if (n.kind === "dependency" && n.realName) {
      lines.push("<div class=\"meta\">" + escapeHtml(n.realName) + "</div>");
    }
    if (n.version) {
      lines.push("<div class=\"meta\">" + escapeHtml(n.version) + "</div>");
    }
    el.innerHTML = lines.join("");
    el.addEventListener("click", function () {
      selectedId = selectedId === id ? null : id;
      applyVisibility();
    });
    canvas.appendChild(el);
    n.el = el;
  });

  edgesList.forEach(function (e) {
    var line = document.createElementNS("http://www.w3.org/2000/svg", "line");
    line.setAttribute("class", "edge");
    edgeGroup.appendChild(line);
    e.el = line;
  });

  var selectedId = null;
  var ancestryDirection = "both";
  var ancestryDepth = null;
  var nameFilter = "";
  var currentVisible = {};

  function ancestrySet(startId, direction, maxDepth) {
    var depthOf = {};
    depthOf[startId] = 0;
    var queue = [ startId ];
    while (queue.length > 0) {
      var cur = queue.shift();
      var d = depthOf[cur];
      if (maxDepth !== null && d >= maxDepth) { continue; }
      var neighbors = [];
      // "ancestors" = what this node depends on (what it's built from --
      // outgoing edges); "descendants" = what depends on this node (its
      // consumers -- incoming edges). A leaf dependency (e.g. zlib) has
      // no outgoing edges of its own, so it correctly has no ancestors,
      // only descendants (whatever nodes consume it).
      if (direction === "ancestors" || direction === "both") {
        neighbors = neighbors.concat(outgoing[cur] || []);
      }
      if (direction === "descendants" || direction === "both") {
        neighbors = neighbors.concat(incoming[cur] || []);
      }
      neighbors.forEach(function (nb) {
        if (!(nb in depthOf)) {
          depthOf[nb] = d + 1;
          queue.push(nb);
        }
      });
    }
    return Object.keys(depthOf);
  }

  function computeVisibleIds() {
    var ids;
    if (selectedId !== null) {
      ids = ancestrySet(selectedId, ancestryDirection, ancestryDepth);
    } else {
      ids = Object.keys(nodesById);
    }
    if (nameFilter) {
      var f = nameFilter.toLowerCase();
      ids = ids.filter(function (id) {
        var n = nodesById[id];
        return n.label.toLowerCase().indexOf(f) !== -1
          || (n.realName && n.realName.toLowerCase().indexOf(f) !== -1);
      });
    }
    return ids;
  }

  function applyVisibility() {
    var visible = {};
    computeVisibleIds().forEach(function (id) { visible[id] = true; });
    currentVisible = visible;

    Object.keys(nodesById).forEach(function (id) {
      var el = nodesById[id].el;
      var sel = id === selectedId;
      el.classList.toggle("hidden", !visible[id]);
      el.classList.toggle("selected", sel);
    });
    edgesList.forEach(function (e) {
      var vis = visible[e.from] && visible[e.to];
      e.el.classList.toggle("hidden", !vis);
    });

    var status = document.getElementById("ancestry-status");
    status.textContent = selectedId === null
      ? "no node selected"
      : "selected: " + nodesById[selectedId].label;
  }

  var REPEL = 12000;
  var SPRING = 0.02;
  var REST_LENGTH = 110;
  var DAMPING = 0.85;
  var SETTLE_STRENGTH = 0.03;
  var SETTLE_BAND = 220;

  function clamp(v, lo, hi) {
    return v < lo ? lo : (v > hi ? hi : v);
  }

  function tick() {
    var W = canvas.clientWidth;
    var H = canvas.clientHeight;
    var ids = Object.keys(currentVisible);

    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        var a = nodesById[ids[i]];
        var b = nodesById[ids[j]];
        var dx = a.x - b.x;
        var dy = a.y - b.y;
        var distSq = dx * dx + dy * dy;
        if (distSq < 1) { distSq = 1; }
        var dist = Math.sqrt(distSq);
        var force = REPEL / distSq;
        var fx = (dx / dist) * force;
        var fy = (dy / dist) * force;
        a.vx += fx; a.vy += fy;
        b.vx -= fx; b.vy -= fy;
      }
    }

    edgesList.forEach(function (e) {
      if (!currentVisible[e.from] || !currentVisible[e.to]) { return; }
      var a = nodesById[e.from];
      var b = nodesById[e.to];
      var dx = b.x - a.x;
      var dy = b.y - a.y;
      var dist = Math.sqrt(dx * dx + dy * dy) || 1;
      var diff = dist - REST_LENGTH;
      var force = diff * SPRING;
      var fx = (dx / dist) * force;
      var fy = (dy / dist) * force;
      a.vx += fx; a.vy += fy;
      b.vx -= fx; b.vy -= fy;
    });

    var rootPinned = selectedId === null && currentVisible[GRAPH.rootId];
    var settleY = null;
    if (rootPinned) {
      var root = nodesById[GRAPH.rootId];
      root.x = W / 2;
      root.y = 50;
      root.vx = 0;
      root.vy = 0;
      settleY = root.y + SETTLE_BAND;
    }

    ids.forEach(function (id) {
      if (rootPinned && id === GRAPH.rootId) { return; }
      var n = nodesById[id];
      // Repulsion/springs alone have no reason to prefer any particular
      // resting point -- a spring pulls a node toward whatever it's
      // connected to just as readily upward (back toward the pinned
      // root) as anywhere else, so without this the whole graph tends to
      // collapse toward the one fixed point in the system instead of
      // settling. This is the actual "root at top, everything else
      // below" constraint, applied as a real (weak) force -- not in
      // effect once the ancestry filter drops the root pin entirely.
      if (settleY !== null) {
        n.vy += (settleY - n.y) * SETTLE_STRENGTH;
      }
      n.vx *= DAMPING;
      n.vy *= DAMPING;
      n.x += n.vx;
      n.y += n.vy;
      n.x = clamp(n.x, 20, W - 20);
      n.y = clamp(n.y, 20, H - 20);
    });

    render();
    window.requestAnimationFrame(tick);
  }

  function render() {
    Object.keys(currentVisible).forEach(function (id) {
      var n = nodesById[id];
      n.el.style.transform = "translate(" + (n.x - n.el.offsetWidth / 2) + "px, " + (n.y - n.el.offsetHeight / 2) + "px)";
    });
    edgesList.forEach(function (e) {
      if (!currentVisible[e.from] || !currentVisible[e.to]) { return; }
      var a = nodesById[e.from];
      var b = nodesById[e.to];
      e.el.setAttribute("x1", a.x);
      e.el.setAttribute("y1", a.y);
      e.el.setAttribute("x2", b.x);
      e.el.setAttribute("y2", b.y);
    });
  }

  document.getElementById("name-filter").addEventListener("input", function (ev) {
    nameFilter = ev.target.value;
    applyVisibility();
  });

  document.querySelectorAll("input[name=\"direction\"]").forEach(function (r) {
    r.addEventListener("change", function (ev) {
      ancestryDirection = ev.target.value;
      applyVisibility();
    });
  });

  document.getElementById("max-depth").addEventListener("input", function (ev) {
    var v = ev.target.value;
    ancestryDepth = v === "" ? null : parseInt(v, 10);
    applyVisibility();
  });

  document.getElementById("clear-selection").addEventListener("click", function () {
    selectedId = null;
    applyVisibility();
  });

  applyVisibility();
  window.requestAnimationFrame(tick);
}());
</script>
</body>
</html>
''
