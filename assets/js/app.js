// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Syntax highlighting (selective language imports to keep bundle small)
import hljs from "highlight.js/lib/core"
import elixir from "highlight.js/lib/languages/elixir"
import javascript from "highlight.js/lib/languages/javascript"
import json from "highlight.js/lib/languages/json"
import bash from "highlight.js/lib/languages/bash"
import css from "highlight.js/lib/languages/css"
import xml from "highlight.js/lib/languages/xml"
import markdown from "highlight.js/lib/languages/markdown"
import yaml from "highlight.js/lib/languages/yaml"
import diff from "highlight.js/lib/languages/diff"

hljs.registerLanguage("elixir", elixir)
hljs.registerLanguage("javascript", javascript)
hljs.registerLanguage("json", json)
hljs.registerLanguage("bash", bash)
hljs.registerLanguage("css", css)
hljs.registerLanguage("xml", xml)
hljs.registerLanguage("html", xml)
hljs.registerLanguage("markdown", markdown)
hljs.registerLanguage("yaml", yaml)
hljs.registerLanguage("diff", diff)

// --- Hooks ---

let Hooks = {}

// ShiftEnterSubmit: submits the form on Enter, allows Shift+Enter for newlines,
// and auto-resizes the textarea as the user types.
Hooks.ShiftEnterSubmit = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        this.el.closest("form").dispatchEvent(
          new Event("submit", { bubbles: true, cancelable: true })
        )
      }
    })

    // Auto-resize on input
    this.el.addEventListener("input", () => this.resize())
    this.resize()

    // Focus input when server pushes focus-input event
    this.handleEvent("focus-input", () => {
      this.el.focus()
    })

    // Clear input when server pushes clear-input event
    this.handleEvent("clear-input", () => {
      this.el.value = ""
      this.el.style.height = "auto"
      this.resize()
    })
  },
  resize() {
    this.el.style.height = "auto"
    const maxHeight = 160 // ~6 lines
    this.el.style.height = Math.min(this.el.scrollHeight, maxHeight) + "px"
  }
}

// ScrollToBottom: auto-scrolls container to bottom when content updates (only if near bottom)
Hooks.ScrollToBottom = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.maybeScrollToBottom())
    this.observer.observe(this.el, { childList: true, subtree: true })
  },
  updated() {
    this.maybeScrollToBottom()
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
  isNearBottom() {
    const threshold = 100
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
  },
  maybeScrollToBottom() {
    if (this.isNearBottom()) {
      this.scrollToBottom()
    }
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

// TabTransition: adds fade-in animation class when tab content appears
Hooks.TabTransition = {
  mounted() {
    this.currentTab = this.el.dataset.tab || this.el.id
    this.el.classList.add("tab-content-enter")
  },
  updated() {
    const newTab = this.el.dataset.tab || this.el.id
    if (this.currentTab !== newTab) {
      this.currentTab = newTab
      // Re-trigger animation only on actual tab change
      this.el.classList.remove("tab-content-enter")
      // Force reflow to restart animation
      void this.el.offsetWidth
      this.el.classList.add("tab-content-enter")
    }
  }
}

// ModelSelector: handles dropdown open/close, click-outside, escape, keyboard nav,
// and paste-back OAuth flow initiation
Hooks.ModelSelector = {
  mounted() {
    this._onKeydown = (e) => {
      if (e.key === "Escape") {
        this.pushEventTo(this.el, "close_dropdown", {})
      }
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        const list = this.el.querySelector("#model-list")
        if (!list) return
        const items = Array.from(list.querySelectorAll("button[phx-click='select_model']"))
        if (items.length === 0) return
        e.preventDefault()
        const focused = list.querySelector("button:focus")
        let idx = items.indexOf(focused)
        if (e.key === "ArrowDown") {
          idx = idx < items.length - 1 ? idx + 1 : 0
        } else {
          idx = idx > 0 ? idx - 1 : items.length - 1
        }
        items[idx].focus()
      }
      if (e.key === "Enter") {
        const list = this.el.querySelector("#model-list")
        if (!list) return
        const focused = list.querySelector("button:focus")
        if (focused) focused.click()
      }
    }
    document.addEventListener("keydown", this._onKeydown)

    // Handle paste-back OAuth flow initiation from server
    this.handleEvent("start_paste_back_flow", ({ authorize_url, provider }) => {
      // Open the provider's auth page in a new window
      window.open(authorize_url, "_blank", "noopener,noreferrer")
    })

    // Handle paste-back submission result
    this.handleEvent("paste_submit_result", ({ status, message, error }) => {
      if (status === "ok") {
        // Success — the LiveView will handle updating the UI via PubSub
      }
      // Errors are handled server-side by updating the component assigns
    })
  },
  updated() {
    // Focus search input when dropdown opens
    const searchInput = this.el.querySelector("#model-search-input")
    if (searchInput) {
      requestAnimationFrame(() => searchInput.focus())
    }
    // Focus paste input when paste modal is shown
    const pasteInput = this.el.querySelector("#paste-code-input")
    if (pasteInput) {
      requestAnimationFrame(() => pasteInput.focus())
    }
  },
  destroyed() {
    document.removeEventListener("keydown", this._onKeydown)
  }
}

// CopyToClipboard: copies data-copy-text content to clipboard, shows brief "Copied!" feedback
Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      const text = this.el.getAttribute("data-copy-text") || ""
      navigator.clipboard.writeText(text).then(() => {
        this.showCopied()
      }).catch(() => {
        // Fallback for older browsers
        const ta = document.createElement("textarea")
        ta.value = text
        ta.style.position = "fixed"
        ta.style.opacity = "0"
        document.body.appendChild(ta)
        ta.select()
        document.execCommand("copy")
        document.body.removeChild(ta)
        this.showCopied()
      })
    })
  },
  showCopied() {
    const originalText = this.el.textContent
    this.el.textContent = "Copied!"
    this.el.classList.add("text-emerald-400")
    setTimeout(() => {
      this.el.textContent = originalText
      this.el.classList.remove("text-emerald-400")
    }, 1500)
  }
}

// KeyboardShortcuts: mission control keyboard shortcuts (Cmd+M, Cmd+., arrows, etc.)
Hooks.KeyboardShortcuts = {
  mounted() {
    this.handleKeydown = (e) => {
      const isInput = e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA'
      const mod = e.metaKey || e.ctrlKey

      // Escape always works (close modals, command palette, etc.)
      if (e.key === 'Escape') {
        e.preventDefault()
        this.pushEvent('keyboard_shortcut', { key: 'escape' })
        return
      }

      // Cmd/Ctrl+K always works (opens command palette even from inputs)
      if (mod && e.key === 'k') {
        e.preventDefault()
        this.pushEvent('keyboard_shortcut', { key: 'command_palette' })
        return
      }

      // Remaining shortcuts disabled in input fields
      if (isInput) return

      if (mod && e.key === 'm') {
        e.preventDefault()
        this.pushEvent('keyboard_shortcut', { key: 'toggle_mode' })
      } else if (mod && e.key === '.') {
        e.preventDefault()
        this.pushEvent('keyboard_shortcut', { key: 'cancel' })
      } else if (mod && e.key >= '1' && e.key <= '5') {
        e.preventDefault()
        this.pushEvent('keyboard_shortcut', { key: `focus_panel_${e.key}` })
      } else if (e.key === '/' && !mod) {
        e.preventDefault()
        this.pushEvent('keyboard_shortcut', { key: 'focus_input' })
      } else if (e.key === 'ArrowLeft' && !mod) {
        e.preventDefault()
        this.pushEvent('keyboard_shortcut', { key: 'prev_agent' })
      } else if (e.key === 'ArrowRight' && !mod) {
        e.preventDefault()
        this.pushEvent('keyboard_shortcut', { key: 'next_agent' })
      } else if (e.key === 'j' && !mod) {
        e.preventDefault()
        this.pushEvent('keyboard_shortcut', { key: 'jump_active_agent' })
      } else if (e.key === 'a' && !mod) {
        e.preventDefault()
        this.pushEvent('keyboard_shortcut', { key: 'toggle_activity' })
      }
    }

    document.addEventListener('keydown', this.handleKeydown)
  },
  destroyed() {
    document.removeEventListener('keydown', this.handleKeydown)
  }
}

// CommandPalette: handles search input focus and result navigation
Hooks.CommandPalette = {
  mounted() {
    const input = this.el.querySelector('#command-palette-input')
    if (input) requestAnimationFrame(() => input.focus())

    this._onKeydown = (e) => {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault()
        const items = Array.from(this.el.querySelectorAll('[data-palette-item]'))
        if (items.length === 0) return

        const focused = this.el.querySelector('[data-palette-item]:focus')
        let idx = items.indexOf(focused)

        if (e.key === 'ArrowDown') {
          idx = idx < items.length - 1 ? idx + 1 : 0
        } else {
          idx = idx > 0 ? idx - 1 : items.length - 1
        }
        items[idx].focus()
      }

      if (e.key === 'Enter') {
        const focused = this.el.querySelector('[data-palette-item]:focus')
        if (focused) {
          e.preventDefault()
          focused.click()
        }
      }
    }
    this.el.addEventListener('keydown', this._onKeydown)
  },
  updated() {
    const input = this.el.querySelector('#command-palette-input')
    if (input && document.activeElement !== input) {
      const items = this.el.querySelectorAll('[data-palette-item]:focus')
      if (items.length === 0) input.focus()
    }
  },
  destroyed() {
    this.el.removeEventListener('keydown', this._onKeydown)
  }
}

// SyntaxHighlight: applies highlight.js syntax highlighting with line numbers
Hooks.SyntaxHighlight = {
  mounted() {
    this.highlight()
  },
  updated() {
    this.highlight()
  },
  highlight() {
    const codeEl = this.el.querySelector("code")
    if (!codeEl) return
    // Remove previous highlighting so hljs re-processes
    codeEl.removeAttribute("data-highlighted")
    hljs.highlightElement(codeEl)
    this.addLineNumbers(codeEl)
  },
  addLineNumbers(codeEl) {
    // Skip if already processed
    if (codeEl.querySelector(".file-preview-line")) return
    const html = codeEl.innerHTML
    const lines = html.split("\n")
    // Wrap each line in a span for CSS counter-based line numbers
    codeEl.innerHTML = lines
      .map(line => `<span class="file-preview-line">${line}</span>`)
      .join("")
  }
}

// AutoResizeTextarea: auto-grows textarea as user types
Hooks.AutoResizeTextarea = {
  mounted() {
    this.el.addEventListener("input", () => this.resize())
    this.resize()

    // Clear and reset on server push
    this.handleEvent("clear-input", () => {
      this.el.value = ""
      this.el.style.height = "auto"
      this.resize()
    })
  },
  resize() {
    this.el.style.height = "auto"
    const maxHeight = 160 // ~6 lines
    this.el.style.height = Math.min(this.el.scrollHeight, maxHeight) + "px"
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#818cf8"}, shadowColor: "rgba(0,0,0,.3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
