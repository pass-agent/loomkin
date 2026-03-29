import {
  cancel,
  intro,
  isCancel,
  note,
  outro,
  spinner,
  text,
} from "@clack/prompts";

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  intro("Scaffold project artifacts");

  const projectName = await text({
    message: "Project name",
    placeholder: "my-cli",
    validate(value) {
      return /^[a-z0-9-]+$/.test(String(value))
        ? undefined
        : "Use lowercase letters, numbers, and hyphens only.";
    },
  });

  if (isCancel(projectName)) {
    cancel("Canceled by user.");
    process.exit(0);
  }

  const s = spinner();
  s.start("Creating files...");
  await sleep(500);
  s.message("Installing dependencies...");
  await sleep(700);
  s.stop("Setup complete.");

  note(`Project created: ${projectName}`, "Done");
  outro("All set.");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
