const list = document.querySelector("#tasks");
const tasks = await (await fetch("/api/tasks")).json();
for (const task of tasks) {
  const item = document.createElement("li");
  item.textContent = task.title;
  list.append(item);
}
