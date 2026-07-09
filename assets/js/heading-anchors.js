(function () {
  const headings = document.querySelectorAll(
    "main h1[id], main h2[id], main h3[id], main h4[id], main h5[id], main h6[id]"
  );

  headings.forEach((heading) => {
    if (heading.querySelector(".heading-anchor")) {
      return;
    }

    const anchor = document.createElement("a");
    anchor.className = "heading-anchor";
    anchor.href = `#${heading.id}`;
    anchor.setAttribute("aria-label", `Link to section: ${heading.textContent}`);
    anchor.textContent = "#";

    heading.append(" ", anchor);
  });
}());
