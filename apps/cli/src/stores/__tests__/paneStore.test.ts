import { expect, test, beforeEach } from "vitest";
import { paneStore } from "../paneStore.js";
import { agentStore } from "../agentStore.js";

function seedAgents(...names: string[]) {
  for (const name of names) {
    agentStore.getState().upsertAgent(name, { role: "agent", status: "idle" });
  }
}

beforeEach(() => {
  paneStore.setState({
    splitMode: false,
    focusedPane: "left",
    selectedAgent: null,
    rightScrollOffset: 0,
  });
  agentStore.getState().clearAgents();
});

test("toggleSplitMode stays off when no agents exist", () => {
  paneStore.getState().toggleSplitMode();
  expect(paneStore.getState().splitMode).toBe(false);
});

test("toggleSplitMode enables split and auto-selects first agent", () => {
  seedAgents("alpha", "beta");
  paneStore.getState().toggleSplitMode();
  const state = paneStore.getState();
  expect(state.splitMode).toBe(true);
  expect(state.selectedAgent).toBe("alpha");
  expect(state.rightScrollOffset).toBe(0);
});

test("toggleSplitMode preserves existing selectedAgent", () => {
  seedAgents("alpha", "beta");
  paneStore.setState({ selectedAgent: "beta" });
  paneStore.getState().toggleSplitMode();
  expect(paneStore.getState().selectedAgent).toBe("beta");
});

test("toggleSplitMode off resets focusedPane to left", () => {
  seedAgents("alpha");
  paneStore.setState({ splitMode: true, focusedPane: "right", selectedAgent: "alpha" });
  paneStore.getState().toggleSplitMode();
  const state = paneStore.getState();
  expect(state.splitMode).toBe(false);
  expect(state.focusedPane).toBe("left");
});

test.each<"left" | "right">(["left", "right"])(
  "setFocusedPane(%s) updates focusedPane",
  (pane) => {
    paneStore.getState().setFocusedPane(pane);
    expect(paneStore.getState().focusedPane).toBe(pane);
  },
);

test("selectAgent sets agent and resets scroll offset", () => {
  paneStore.setState({ rightScrollOffset: 10 });
  paneStore.getState().selectAgent("beta");
  expect(paneStore.getState().selectedAgent).toBe("beta");
  expect(paneStore.getState().rightScrollOffset).toBe(0);
});

test("cycleAgent forward wraps around", () => {
  seedAgents("alpha", "beta", "gamma");
  paneStore.setState({ selectedAgent: "gamma" });
  paneStore.getState().cycleAgent(1);
  expect(paneStore.getState().selectedAgent).toBe("alpha");
});

test("cycleAgent backward wraps around", () => {
  seedAgents("alpha", "beta", "gamma");
  paneStore.setState({ selectedAgent: "alpha" });
  paneStore.getState().cycleAgent(-1);
  expect(paneStore.getState().selectedAgent).toBe("gamma");
});

test("cycleAgent is a no-op when no agents exist", () => {
  paneStore.setState({ selectedAgent: "stale" });
  paneStore.getState().cycleAgent(1);
  expect(paneStore.getState().selectedAgent).toBe("stale");
});

test("setRightScrollOffset clamps to zero", () => {
  paneStore.getState().setRightScrollOffset(-5);
  expect(paneStore.getState().rightScrollOffset).toBe(0);
});

test("setRightScrollOffset sets positive values", () => {
  paneStore.getState().setRightScrollOffset(15);
  expect(paneStore.getState().rightScrollOffset).toBe(15);
});
