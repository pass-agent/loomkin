import {
  cancel,
  confirm,
  intro,
  isCancel,
  note,
  outro,
  text,
} from "@clack/prompts";

async function main() {
  intro("Create a new release plan");

  const version = await text({
    message: "Version",
    placeholder: "1.2.0",
    validate(value) {
      return /^\d+\.\d+\.\d+$/.test(String(value))
        ? undefined
        : "Use semver format: 1.2.0";
    },
  });

  if (isCancel(version)) {
    cancel("Canceled by user.");
    process.exit(0);
  }

  const includeChangelog = await confirm({
    message: "Generate changelog?",
    initialValue: true,
  });

  if (isCancel(includeChangelog)) {
    cancel("Canceled by user.");
    process.exit(0);
  }

  note(
    [
      `Version: ${version}`,
      `Generate changelog: ${includeChangelog ? "yes" : "no"}`,
    ].join("\n"),
    "Summary"
  );

  outro("Release plan ready.");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
