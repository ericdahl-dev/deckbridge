/* The web capture page (#190): only the DOM around capture.js, which holds the logic and its tests. It asks for MIDI
   only when Start is pressed, never for SysEx, never sends MIDI out, and uploads nothing: the file is downloaded and
   the owner chooses whether to email it. */
(function () {
  "use strict";
  var C = window.DeckBridgeCapture;
  var APP_VERSION = "web 1.1.0";
  var IDLE_SECONDS = 5;

  function $(id) { return document.getElementById(id); }
  function show(id, on) { $(id).hidden = !on; }
  function now() { return performance.now() / 1000; }

  // Safari and other browsers without Web MIDI: say so and point to the app or another browser.
  if (typeof navigator.requestMIDIAccess !== "function") {
    show("cap-unsupported", true);
    show("cap-intro", false);
    return;
  }

  var access = null, input = null, run = null, idleTimer = null;

  $("cap-start").addEventListener("click", function () {
    $("cap-message").textContent = "";
    navigator.requestMIDIAccess({ sysex: false }).then(function (granted) {
      access = granted;
      var select = $("cap-port");
      select.textContent = "";
      access.inputs.forEach(function (port) {
        var option = document.createElement("option");
        option.value = port.id;
        option.textContent = port.name;
        select.appendChild(option);
      });
      if (!select.options.length) {
        $("cap-message").textContent = "No MIDI controller found. Plug it in, then press Start again.";
        return;
      }
      show("cap-intro", false);
      show("cap-pick", true);
    }, function () {
      $("cap-message").textContent = "The browser didn't allow MIDI. Allow it for this site, then press Start again.";
    });
  });

  $("cap-begin").addEventListener("click", function () {
    input = access.inputs.get($("cap-port").value);
    if (!input) return;
    fetch("prompts.json").then(function (response) { return response.json(); }).then(function (prompts) {
      run = C.session({ appVersion: APP_VERSION, device: input.name, ports: { input: [input.name], output: [] }, prompts: prompts });
      input.onmidimessage = function (event) {
        run.receive(Array.prototype.slice.call(event.data), event.timeStamp / 1000, 0);
        refresh();
      };
      show("cap-pick", false);
      show("cap-step", true);
      startStep();
    });
  });

  function startStep() {
    clearTimeout(idleTimer);
    var prompt = run.current();
    if (!prompt) return finish();
    var at = run.position();
    $("cap-count").textContent = "Step " + at.step + " of " + at.of;
    $("cap-prompt").textContent = prompt.text;
    $("cap-next").disabled = true;
    if (prompt.gesture === "idle") {
      $("cap-heard").textContent = "Hands off: Next comes on in " + IDLE_SECONDS + " seconds.";
      idleTimer = setTimeout(function () { $("cap-next").disabled = false; $("cap-heard").textContent = "Done. Press Next."; },
        IDLE_SECONDS * 1000);
    } else {
      $("cap-heard").textContent = "Waiting for your controller…";
    }
  }

  function refresh() {
    var prompt = run.current();
    if (!prompt || prompt.gesture === "idle") return;
    if (run.hasTake()) {
      $("cap-next").disabled = false;
      $("cap-heard").textContent = "Heard it. Press Next, or Redo to try again.";
    }
  }

  $("cap-next").addEventListener("click", function () { run.confirm(now()); startStep(); });
  $("cap-redo").addEventListener("click", function () { run.redo(now()); startStep(); });
  $("cap-skip").addEventListener("click", function () { run.skip(now()); startStep(); });

  function finish() {
    if (input) input.onmidimessage = null;
    var file = run.file();
    var list = $("cap-summary");
    list.textContent = "";
    C.summary(file).forEach(function (line) {
      var item = document.createElement("li");
      item.textContent = line;
      list.appendChild(item);
    });
    $("cap-mailto").href = "mailto:" + C.emailRecipient + "?subject=" + encodeURIComponent(C.emailSubject(file.device)) +
      "&body=" + encodeURIComponent(C.emailBody(file.device));
    show("cap-step", false);
    show("cap-done", true);
    $("cap-download").onclick = function () {
      var url = URL.createObjectURL(new Blob([C.fileJSON(file)], { type: "application/json" }));
      var link = document.createElement("a");
      link.href = url;
      link.download = C.fileName(file.device);
      document.body.appendChild(link);
      link.click();
      link.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
      show("cap-sent", true);
    };
  }
})();
