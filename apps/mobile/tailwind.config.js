/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./src/**/*.{js,jsx,ts,tsx}"],
  presets: [require("nativewind/preset")],
  theme: {
    extend: {
      colors: {
        primary: {
          DEFAULT: "#6366f1",
          dark: "#4f46e5",
          light: "#818cf8",
        },
        secondary: "#8b5cf6",
        background: "#0f0f23",
        surface: {
          DEFAULT: "#1a1a2e",
          light: "#252547",
        },
        text: {
          DEFAULT: "#e2e8f0",
          secondary: "#94a3b8",
          muted: "#64748b",
        },
        border: "#334155",
        success: "#22c55e",
        warning: "#f59e0b",
        error: "#ef4444",
        info: "#3b82f6",
        "user-bubble": "#6366f1",
        "assistant-bubble": "#1e293b",
        "system-bubble": "#374151",
        "tool-bubble": "#1e1e3a",
      },
      spacing: {
        xs: "4px",
        sm: "8px",
        md: "12px",
        lg: "16px",
        xl: "20px",
        "2xl": "24px",
        "3xl": "32px",
        "4xl": "40px",
      },
      fontSize: {
        xs: "10px",
        sm: "12px",
        base: "14px",
        md: "16px",
        lg: "18px",
        xl: "20px",
        "2xl": "24px",
        "3xl": "30px",
      },
    },
  },
  plugins: [],
};
