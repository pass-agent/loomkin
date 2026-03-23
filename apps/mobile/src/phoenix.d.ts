declare module "phoenix" {
  export class Socket {
    constructor(endPoint: string, opts?: Record<string, any>);
    connect(): void;
    disconnect(callback?: () => void, code?: number, reason?: string): void;
    isConnected(): boolean;
    channel(topic: string, chanParams?: Record<string, unknown>): Channel;
    onError(callback: (error: any) => void): void;
    onClose(callback: (event: any) => void): void;
    onOpen(callback: () => void): void;
  }

  export class Channel {
    join(timeout?: number): Push;
    leave(timeout?: number): Push;
    push(event: string, payload: Record<string, unknown>, timeout?: number): Push;
    on(event: string, callback: (payload: any) => void): number;
    off(event: string, ref?: number): void;
    onError(callback: (reason?: any) => void): void;
    onClose(callback: (payload: any, ref: any, joinRef: any) => void): void;
  }

  export class Push {
    receive(status: string, callback: (response: any) => void): Push;
  }

  export class Presence {
    constructor(channel: Channel);
    onJoin(callback: (key: string, current: any, newPres: any) => void): void;
    onLeave(callback: (key: string, current: any, leftPres: any) => void): void;
    onSync(callback: () => void): void;
    list(by?: (key: string, presence: any) => any): any[];
  }
}
