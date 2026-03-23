module.exports = function (api) {
  api.cache(true);

  const presets = [
    ["babel-preset-expo", { jsxImportSource: "nativewind" }],
    "nativewind/babel",
  ];

  const plugins = [];

  // Reanimated v4 uses worklets via its own SWC transform, not a Babel plugin.
  // Only add the Babel plugin if we detect v3 (which still needs it).
  try {
    const reanimatedPkg = require("react-native-reanimated/package.json");
    const major = parseInt(reanimatedPkg.version.split(".")[0], 10);
    if (major < 4) {
      plugins.push("react-native-reanimated/plugin");
    }
  } catch {
    // reanimated not installed — skip
  }

  return { presets, plugins };
};
