window.addEventListener("pocket-feed", ({ detail }) => {
  const heading = document.getElementById("title");
  const notes = document.getElementById("notes");
  heading.textContent = detail.title;
  document.title = detail.title;
  notes.replaceChildren(...detail.items.map(({ title, body }) => {
    const item = document.createElement("li");
    const titleElement = document.createElement("h2");
    const bodyElement = document.createElement("p");
    titleElement.textContent = title;
    bodyElement.textContent = body;
    item.append(titleElement, bodyElement);
    return item;
  }));
});
