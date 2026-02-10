document.addEventListener("DOMContentLoaded", function () {
  var footnotes = document.querySelectorAll(".footnote-definition");
  if (footnotes.length === 0) return;

  // --- Renumber footnotes sequentially based on reference order ---
  var refs = document.querySelectorAll("sup.footnote-reference a");
  var labelToNum = {};
  var orderedLabels = [];
  var counter = 0;

  refs.forEach(function (ref) {
    var href = ref.getAttribute("href");
    var originalLabel = href.substring(1);
    if (!(originalLabel in labelToNum)) {
      counter++;
      labelToNum[originalLabel] = counter;
      orderedLabels.push(originalLabel);
    }
    ref.textContent = labelToNum[originalLabel];
  });

  // Update displayed number in each footnote definition label
  var defMap = {};
  footnotes.forEach(function (footnote) {
    var id = footnote.getAttribute("id");
    defMap[id] = footnote;
    if (id in labelToNum) {
      var label = footnote.querySelector("sup.footnote-definition-label");
      if (label) {
        label.textContent = labelToNum[id];
      }
    }
  });

  // --- Reorder footnote definitions to match reference order ---
  // Use a placeholder so insertBefore works correctly
  var parent = footnotes[0].parentNode;
  var placeholder = document.createComment("footnotes");
  parent.insertBefore(placeholder, footnotes[0]);

  // Remove all definitions from DOM
  footnotes.forEach(function (fn) {
    fn.parentNode.removeChild(fn);
  });

  // Re-insert in reference order (1, 2, 3...)
  orderedLabels.forEach(function (label) {
    if (defMap[label]) {
      parent.insertBefore(defMap[label], placeholder);
      delete defMap[label];
    }
  });

  // Append any orphan definitions at the end
  Object.keys(defMap).forEach(function (key) {
    parent.insertBefore(defMap[key], placeholder);
  });

  parent.removeChild(placeholder);

  // --- Add "Footnotes" heading above the first footnote ---
  var reorderedFootnotes = document.querySelectorAll(".footnote-definition");
  var firstFootnote = reorderedFootnotes[0];
  var heading = document.createElement("h2");
  heading.textContent = "Footnotes";
  heading.className = "footnotes-heading";
  firstFootnote.parentNode.insertBefore(heading, firstFootnote);

  // --- Add IDs to footnote references for back-referencing ---
  refs.forEach(function (ref) {
    var href = ref.getAttribute("href");
    var fnId = href.substring(1);
    var sup = ref.closest("sup");
    sup.id = "fnref-" + fnId;

    ref.addEventListener("click", function (e) {
      e.preventDefault();
      var footnote = document.getElementById(fnId);
      if (footnote) {
        footnote.scrollIntoView({ behavior: "smooth", block: "center" });
        footnote.classList.add("footnote-highlight");
        setTimeout(function () {
          footnote.classList.remove("footnote-highlight");
        }, 2000);
      }
    });
  });

  // --- Add back references to footnotes ---
  reorderedFootnotes.forEach(function (footnote) {
    var id = footnote.getAttribute("id");
    var backRef = document.createElement("a");
    backRef.href = "#fnref-" + id;
    backRef.className = "footnote-backref";
    backRef.innerHTML = " \u21a9";
    backRef.setAttribute("aria-label", "Back to reference");

    backRef.addEventListener("click", function (e) {
      e.preventDefault();
      var sup = document.getElementById("fnref-" + id);
      if (sup) {
        sup.scrollIntoView({ behavior: "smooth", block: "center" });
        sup.classList.add("sup-highlight");
        setTimeout(function () {
          sup.classList.remove("sup-highlight");
        }, 2000);
      }
    });

    var p = footnote.querySelector("p");
    if (p) {
      p.appendChild(backRef);
    }
  });
});
