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

// --- Tooltip anchor fix ---
// CSS anchor-name is tied to :hover, so when hover ends the anchor disappears
// immediately — causing the fixed tooltip to jump before it fades out.
// This keeps the anchor valid for the duration of the exit transition.
document.addEventListener("mouseleave", (e) => {
  const el = e.target.closest?.("[data-tooltip]")
  if (!el) return
  el.classList.add("tooltip-exiting")
  setTimeout(() => el.classList.remove("tooltip-exiting"), 200)
}, { capture: true })

// --- Utilities ---

function trapFocus(containerEl) {
  const focusable = containerEl.querySelectorAll(
    'a[href], button:not([disabled]), input, textarea, select, [tabindex]:not([tabindex="-1"])'
  )
  const first = focusable[0], last = focusable[focusable.length - 1]
  return (e) => {
    if (e.key !== 'Tab') return
    if (e.shiftKey ? document.activeElement === first : document.activeElement === last) {
      e.preventDefault()
      ;(e.shiftKey ? last : first).focus()
    }
  }
}

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
// Shows a "New messages" indicator button when content arrives while scrolled up.
Hooks.ScrollToBottom = {
  mounted() {
    this.isAtBottom = true

    this.el.addEventListener("scroll", () => {
      this.isAtBottom = this.nearBottom()
      if (this.isAtBottom) this.hideIndicator()
    })

    this.observer = new MutationObserver(() => {
      if (this.isAtBottom) {
        this.scrollToBottom()
      } else {
        this.showIndicator()
      }
    })
    this.observer.observe(this.el, { childList: true, subtree: true })

    const indicator = this.getIndicator()
    if (indicator) {
      indicator.addEventListener("click", () => {
        this.scrollToBottom()
        this.hideIndicator()
      })
    }

    this.scrollToBottom()
  },
  updated() {
    if (this.isAtBottom) this.scrollToBottom()
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
  nearBottom() {
    const threshold = 100
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
  getIndicator() {
    return this.el.parentElement.querySelector("[data-scroll-indicator]")
  },
  showIndicator() {
    const el = this.getIndicator()
    if (!el) return
    el.classList.remove("opacity-0", "pointer-events-none")
    el.classList.add("opacity-100")
  },
  hideIndicator() {
    const el = this.getIndicator()
    if (!el) return
    el.classList.remove("opacity-100")
    el.classList.add("opacity-0", "pointer-events-none")
  }
}

// TabTransition: adds fade-in animation class when tab content appears.
// Uses View Transitions API when available for smooth cross-fades.
Hooks.TabTransition = {
  mounted() {
    this.currentTab = this.el.dataset.tab || this.el.id
    this.el.classList.add("tab-content-enter", "tab-content-panel")
  },
  updated() {
    const newTab = this.el.dataset.tab || this.el.id
    if (this.currentTab !== newTab) {
      this.currentTab = newTab
      const triggerAnimation = () => {
        this.el.classList.remove("tab-content-enter")
        void this.el.offsetWidth // force reflow
        this.el.classList.add("tab-content-enter")
      }
      if (document.startViewTransition) {
        document.startViewTransition(triggerAnimation)
      } else {
        triggerAnimation()
      }
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

// CommandPalette: handles search input focus, result navigation, and focus trapping
Hooks.CommandPalette = {
  mounted() {
    this._prevFocus = document.activeElement

    const input = this.el.querySelector('#command-palette-input')
    if (input) requestAnimationFrame(() => input.focus())

    this._trapHandler = trapFocus(this.el)
    this.el.addEventListener('keydown', this._trapHandler)

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
    this.el.removeEventListener('keydown', this._trapHandler)
    this._prevFocus?.focus()
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

// ResizablePanel: drag left edge to resize the inspector panel width
Hooks.ResizablePanel = {
  mounted() {
    const handle = this.el.querySelector('#inspector-resize-handle')
    if (!handle) return

    const MIN_WIDTH = 200
    const MAX_WIDTH = 900
    const DEFAULT_WIDTH = 320

    // Restore saved width
    const saved = localStorage.getItem('inspector-width')
    if (saved) {
      this.el.style.width = saved + 'px'
    } else {
      this.el.style.width = DEFAULT_WIDTH + 'px'
    }

    let dragging = false
    let startX = 0
    let startWidth = 0

    const onMouseDown = (e) => {
      e.preventDefault()
      dragging = true
      startX = e.clientX
      startWidth = this.el.getBoundingClientRect().width
      document.body.style.cursor = 'col-resize'
      document.body.style.userSelect = 'none'
    }

    const onMouseMove = (e) => {
      if (!dragging) return
      // Panel is on the right, so dragging left = wider
      const delta = startX - e.clientX
      const newWidth = Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, startWidth + delta))
      this.el.style.width = newWidth + 'px'
    }

    const onMouseUp = () => {
      if (!dragging) return
      dragging = false
      document.body.style.cursor = ''
      document.body.style.userSelect = ''
      const width = this.el.getBoundingClientRect().width
      localStorage.setItem('inspector-width', Math.round(width))
    }

    handle.addEventListener('mousedown', onMouseDown)
    document.addEventListener('mousemove', onMouseMove)
    document.addEventListener('mouseup', onMouseUp)

    this._cleanup = () => {
      handle.removeEventListener('mousedown', onMouseDown)
      document.removeEventListener('mousemove', onMouseMove)
      document.removeEventListener('mouseup', onMouseUp)
    }
  },
  destroyed() {
    if (this._cleanup) this._cleanup()
  }
}

// VerticalSplit: drag handle to resize top/bottom pane split
Hooks.VerticalSplit = {
  mounted() {
    const handle = this.el.querySelector('#mc-split-handle')
    const topPane = this.el.querySelector('#mc-top-pane')
    if (!handle || !topPane) return

    const MIN_TOP = 120
    const MIN_BOTTOM = 150

    // Set initial height from saved preference or 40% default
    const setInitialHeight = () => {
      const containerHeight = this.el.getBoundingClientRect().height
      if (containerHeight === 0) return // not laid out yet
      const savedPct = localStorage.getItem('mc-split-pct')
      const pct = savedPct ? parseInt(savedPct) : 40
      topPane.style.height = Math.max(MIN_TOP, (containerHeight * pct) / 100) + 'px'
    }

    setInitialHeight()
    // Retry in case layout isn't ready on first mount
    requestAnimationFrame(() => setInitialHeight())

    let dragging = false
    let startY = 0
    let startHeight = 0

    const onMouseDown = (e) => {
      e.preventDefault()
      dragging = true
      startY = e.clientY
      startHeight = topPane.getBoundingClientRect().height
      document.body.style.cursor = 'row-resize'
      document.body.style.userSelect = 'none'
    }

    const onMouseMove = (e) => {
      if (!dragging) return
      const ch = this.el.getBoundingClientRect().height
      const delta = e.clientY - startY
      const newHeight = Math.max(MIN_TOP, Math.min(ch - MIN_BOTTOM, startHeight + delta))
      topPane.style.height = newHeight + 'px'
    }

    const onMouseUp = () => {
      if (!dragging) return
      dragging = false
      document.body.style.cursor = ''
      document.body.style.userSelect = ''
      const ch = this.el.getBoundingClientRect().height
      const pct = Math.round((topPane.getBoundingClientRect().height / ch) * 100)
      localStorage.setItem('mc-split-pct', pct)
    }

    handle.addEventListener('mousedown', onMouseDown)
    document.addEventListener('mousemove', onMouseMove)
    document.addEventListener('mouseup', onMouseUp)

    this._cleanup = () => {
      handle.removeEventListener('mousedown', onMouseDown)
      document.removeEventListener('mousemove', onMouseMove)
      document.removeEventListener('mouseup', onMouseUp)
    }
  },
  destroyed() {
    if (this._cleanup) this._cleanup()
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

// LocalTime: formats UTC timestamps in the user's local timezone,
// and live-updates countdowns and relative times every second.
Hooks.LocalTime = {
  mounted() {
    this.updateTime()
    this.timer = setInterval(() => this.updateTime(), 1000)
  },
  updated() {
    this.updateTime()
  },
  destroyed() {
    if (this.timer) clearInterval(this.timer)
  },
  updateTime() {
    const utcTime = this.el.dataset.utcTime
    if (!utcTime) return

    const format = this.el.dataset.format || "time"
    const dt = new Date(utcTime)
    const now = new Date()

    if (format === "time") {
      this.el.textContent = dt.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    } else if (format === "countdown") {
      const diffSec = Math.floor((dt - now) / 1000)
      if (diffSec <= 0) {
        this.el.textContent = "delivering..."
      } else if (diffSec < 60) {
        this.el.textContent = `in ${diffSec}s`
      } else if (diffSec < 3600) {
        this.el.textContent = `in ${Math.floor(diffSec / 60)}m`
      } else {
        const h = Math.floor(diffSec / 3600)
        const m = Math.floor((diffSec % 3600) / 60)
        this.el.textContent = `in ${h}h ${m}m`
      }
    } else if (format === "relative") {
      const diffSec = Math.floor((now - dt) / 1000)
      if (diffSec < 60) {
        this.el.textContent = `${diffSec}s ago`
      } else if (diffSec < 3600) {
        this.el.textContent = `${Math.floor(diffSec / 60)}m ago`
      } else if (diffSec < 86400) {
        this.el.textContent = `${Math.floor(diffSec / 3600)}h ago`
      } else {
        this.el.textContent = `${Math.floor(diffSec / 86400)}d ago`
      }
    }
  }
}

// CommsFeedScroll: auto-scrolls comms feed when at bottom, shows "N new messages" indicator when scrolled up
Hooks.CommsFeedScroll = {
  mounted() {
    this.isAtBottom = true
    this.newCount = 0

    this.el.addEventListener("scroll", () => {
      const threshold = 50
      const atBottom =
        this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
      this.isAtBottom = atBottom
      if (atBottom) {
        this.newCount = 0
        this.hideIndicator()
      }
    })

    this.el.addEventListener("scroll-to-bottom", () => {
      this.el.scrollTop = this.el.scrollHeight
      this.newCount = 0
      this.hideIndicator()
    })

    this.observer = new MutationObserver((mutations) => {
      if (this.isAtBottom) {
        requestAnimationFrame(() => {
          this.el.scrollTop = this.el.scrollHeight
        })
      } else {
        const added = mutations.reduce(
          (count, m) => count + m.addedNodes.length, 0
        )
        if (added > 0) {
          this.newCount += added
          this.showIndicator(this.newCount)
        }
      }
    })

    this.observer.observe(this.el, { childList: true })
  },

  showIndicator(count) {
    const indicator = this.el.parentElement.querySelector("[data-new-messages]")
    if (indicator) {
      indicator.textContent = `${count} new message${count === 1 ? "" : "s"}`
      indicator.classList.remove("hidden")
    }
  },

  hideIndicator() {
    const indicator = this.el.parentElement.querySelector("[data-new-messages]")
    if (indicator) indicator.classList.add("hidden")
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
  }
}

// CountdownTimer: ticks down from data-deadline-at (wall-clock ms) to zero, clears interval on destroy
Hooks.CountdownTimer = {
  mounted() {
    this.tick()
    this.intervalId = setInterval(() => this.tick(), 1000)
  },
  tick() {
    const deadline = parseInt(this.el.dataset.deadlineAt, 10)
    const remaining = Math.max(0, Math.ceil((deadline - Date.now()) / 1000))
    const minutes = Math.floor(remaining / 60)
    const seconds = remaining % 60
    this.el.textContent = `${minutes}:${seconds.toString().padStart(2, '0')}`
    if (remaining === 0) {
      clearInterval(this.intervalId)
    }
  },
  destroyed() {
    clearInterval(this.intervalId)
  }
}

Hooks.SortableQueue = {
  mounted() {
    this._cleanups = []
    this.initSortable()
  },
  updated() {
    this.cleanup()
    this.initSortable()
  },
  destroyed() {
    this.cleanup()
  },
  cleanup() {
    for (const { el, event, handler } of this._cleanups) {
      el.removeEventListener(event, handler)
    }
    this._cleanups = []
  },
  initSortable() {
    const items = this.el.querySelectorAll("[data-id]")
    const handles = this.el.querySelectorAll(".drag-handle")

    handles.forEach((handle, i) => {
      const item = items[i]
      if (!item) return

      handle.setAttribute("draggable", "true")

      const onDragstart = (e) => {
        item.classList.add("opacity-50")
        e.dataTransfer.effectAllowed = "move"
        e.dataTransfer.setData("text/plain", item.dataset.id)
      }
      const onDragend = () => {
        item.classList.remove("opacity-50")
      }

      handle.addEventListener("dragstart", onDragstart)
      handle.addEventListener("dragend", onDragend)
      this._cleanups.push({ el: handle, event: "dragstart", handler: onDragstart })
      this._cleanups.push({ el: handle, event: "dragend", handler: onDragend })
    })

    const onDragover = (e) => {
      e.preventDefault()
      e.dataTransfer.dropEffect = "move"
    }
    const onDrop = (e) => {
      e.preventDefault()
      const allItems = [...this.el.querySelectorAll("[data-id]")]
      const ordered = allItems.map(el => el.dataset.id)
      const agent = this.el.dataset.agent
      this.pushEvent("reorder_queue", {agent: agent, ids: ordered})
    }

    this.el.addEventListener("dragover", onDragover)
    this.el.addEventListener("drop", onDrop)
    this._cleanups.push({ el: this.el, event: "dragover", handler: onDragover })
    this._cleanups.push({ el: this.el, event: "drop", handler: onDrop })
  }
}

// WorkspaceState: saves UI layout state to localStorage via data attributes.
// On updated(), reads current state from data-* attrs and persists.
// On mounted(), restores saved state by pushing to server.
Hooks.WorkspaceState = {
  mounted() {
    const sessionId = this.el.dataset.sessionId
    if (!sessionId) return

    const saved = JSON.parse(localStorage.getItem(`loomkin_ui:${sessionId}`) || "null")
    if (saved) {
      this.pushEvent("restore_ui_state", saved)
    }
  },
  updated() {
    const d = this.el.dataset
    if (!d.sessionId) return

    const state = {
      mode: d.mode,
      active_tab: d.activeTab,
      focused_agent: d.focusedAgent || null,
      inspector_mode: d.inspectorMode,
      collapsed_inspector: d.collapsedInspector === "true",
      social_panel_open: d.socialPanelOpen === "true"
    }
    localStorage.setItem(`loomkin_ui:${d.sessionId}`, JSON.stringify(state))
  }
}

// SessionMemory: persists the active session per project to localStorage
// so code reloads snap back to the right session instead of the first one.
Hooks.SessionMemory = {
  mounted() {
    this.save()
  },
  updated() {
    this.save()
  },
  save() {
    const sessionId = this.el.dataset.sessionId
    const projectPath = this.el.dataset.projectPath
    if (sessionId && projectPath) {
      const sessions = JSON.parse(localStorage.getItem("loomkin_sessions") || "{}")
      sessions[projectPath] = sessionId
      localStorage.setItem("loomkin_sessions", JSON.stringify(sessions))
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({
    _csrf_token: csrfToken,
    stored_sessions: JSON.parse(localStorage.getItem("loomkin_sessions") || "{}")
  }),
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
