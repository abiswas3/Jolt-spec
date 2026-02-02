document.addEventListener("DOMContentLoaded", function () {
  // First, add IDs to footnote references in the text
  document.querySelectorAll("sup.footnote-reference a").forEach(function (ref) {
    const href = ref.getAttribute("href");
    const fnId = href.substring(1); // Remove the '#'
    const refId = "fnref-" + fnId;

    // Wrap the sup in a span with an ID for back-referencing
    const sup = ref.closest("sup");
    sup.id = refId;

    // Add click handler to highlight footnote
    ref.addEventListener("click", function (e) {
      e.preventDefault();
      const footnote = document.getElementById(fnId);
      if (footnote) {
        footnote.scrollIntoView({ behavior: "smooth", block: "center" });
        footnote.classList.add("footnote-highlight");
        setTimeout(() => footnote.classList.remove("footnote-highlight"), 2000);
      }
    });
  });

  // Then add back references to footnotes
  document
    .querySelectorAll(".footnote-definition")
    .forEach(function (footnote) {
      const id = footnote.getAttribute("id");
      const backRef = document.createElement("a");
      backRef.href = "#fnref-" + id;
      backRef.className = "footnote-backref";
      backRef.innerHTML = " ↩";
      backRef.setAttribute("aria-label", "Back to reference");

      // Add click handler for back reference
      backRef.addEventListener("click", function (e) {
        e.preventDefault();
        const sup = document.getElementById("fnref-" + id);
        if (sup) {
          sup.scrollIntoView({ behavior: "smooth", block: "center" });
          sup.classList.add("sup-highlight");
          setTimeout(() => sup.classList.remove("sup-highlight"), 2000);
        }
      });

      const p = footnote.querySelector("p");
      if (p) {
        p.appendChild(backRef);
      }
    });
});
