// Opens a screenshot full screen. Arrow keys, swiping and the buttons step through all of them;
// Escape, the close button or a click beside the image closes it. Without JavaScript the links
// open the image file itself.
(() => {
  const links = [...document.querySelectorAll("a.shot")];
  if (!links.length || !window.HTMLDialogElement) return;

  const icon = (path) =>
    `<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path d="${path}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
  const dialog = document.createElement("dialog");
  dialog.className = "lightbox";
  dialog.setAttribute("aria-label", "Screenshots");
  dialog.innerHTML = `
    <figure><img alt=""><figcaption></figcaption></figure>
    <button type="button" class="close" aria-label="Close">${icon("M6 6l12 12M18 6L6 18")}</button>
    <button type="button" class="prev" aria-label="Previous screenshot">${icon("M15 5l-7 7 7 7")}</button>
    <button type="button" class="next" aria-label="Next screenshot">${icon("M9 5l7 7-7 7")}</button>`;
  document.body.append(dialog);
  const image = dialog.querySelector("img");
  const caption = dialog.querySelector("figcaption");
  image.addEventListener("load", () => image.classList.remove("loading"));
  let index = 0;

  const show = (next) => {
    index = (next + links.length) % links.length;
    const link = links[index];
    // Hidden until loaded, so the previous screenshot never shows under the new caption.
    if (image.getAttribute("src") !== link.getAttribute("href")) {
      image.classList.add("loading");
      image.src = link.getAttribute("href");
    }
    image.alt = link.querySelector("img").alt;
    const title = link.closest("figure")?.querySelector("figcaption")?.textContent ?? "";
    caption.textContent = `${title} · ${index + 1} of ${links.length}`;
    // Neighbours load in the background so stepping is instant.
    for (const step of [-1, 1]) new Image().src = links[(index + step + links.length) % links.length].href;
  };

  links.forEach((link, position) => link.addEventListener("click", (event) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    show(position);
    dialog.showModal();
  }));
  dialog.querySelector(".prev").addEventListener("click", () => show(index - 1));
  dialog.querySelector(".next").addEventListener("click", () => show(index + 1));
  dialog.querySelector(".close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog || event.target.tagName === "FIGURE") dialog.close();
  });
  dialog.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") show(index - 1);
    else if (event.key === "ArrowRight") show(index + 1);
  });

  let startX = null;
  image.addEventListener("pointerdown", (event) => { startX = event.clientX; });
  image.addEventListener("pointerup", (event) => {
    if (startX === null) return;
    const distance = event.clientX - startX;
    startX = null;
    if (Math.abs(distance) > 40) show(index + (distance < 0 ? 1 : -1));
  });
  image.addEventListener("dragstart", (event) => event.preventDefault());
})();
