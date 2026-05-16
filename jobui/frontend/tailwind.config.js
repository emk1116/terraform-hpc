/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,jsx}"],
  theme: {
    extend: {
      fontFamily: {
        display: ['"JetBrains Mono"', "monospace"],
        sans: ['"Inter"', "system-ui", "sans-serif"],
      },
      colors: {
        ink: "#0a0a0a",
        paper: "#fafaf9",
        accent: "#d4ff00",
        muted: "#737373",
        border: "#e5e5e5",
      },
    },
  },
  plugins: [],
};
