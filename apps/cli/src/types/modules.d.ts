declare module "phoenix" {
  export class Socket {
    constructor(endPoint: string, opts?: Record<string, unknown>);
    connect(): void;
    disconnect(): void;
    isConnected(): boolean;
    channel(topic: string, params?: Record<string, unknown>): Channel;
    onOpen(callback: () => void): void;
    onError(callback: (error: unknown) => void): void;
    onClose(callback: () => void): void;
  }

  export class Channel {
    join(): Push;
    leave(): Push;
    on(event: string, callback: (payload: any) => void): void;
    off(event: string): void;
    push(event: string, payload?: Record<string, unknown>): Push;
  }

  export class Push {
    receive(status: string, callback: (response: Record<string, unknown>) => void): Push;
  }
}

declare module "marked-terminal" {
  import type { MarkedExtension } from "marked";
  export default function markedTerminal(
    options?: Record<string, unknown>,
  ): MarkedExtension;
}
