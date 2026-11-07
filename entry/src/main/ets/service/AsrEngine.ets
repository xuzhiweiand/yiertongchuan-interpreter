/** 语音识别引擎抽象：中→英用系统离线识别，英→中用云端识别。 */
export interface AsrEngine {
  onPartial: (text: string) => void;
  onFinal: (text: string) => void;
  onError: (code: number, message: string) => void;
  onListening: () => void;
  onStopped: () => void;

  start(): Promise<void>;

  stop(): void;

  suspend(): void;

  resume(): Promise<void>;

  shutdown(): void;

  readonly isRunning: boolean;
}
