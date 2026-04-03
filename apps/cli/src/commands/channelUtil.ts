import { useChannelStore } from "../stores/channelStore.js";
import type { Channel } from "phoenix";

export function getSessionChannel(): Channel | null {
  return useChannelStore.getState().getChannel();
}
