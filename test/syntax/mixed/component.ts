import type { Model } from "./model";
export interface Props { model: Model; fallback?: string; }
export class Presenter {
  constructor(publicName: string) { this.name = publicName; }
  render(props: Props): string {
    const label = props.model?.label ?? props.fallback ?? "unknown";
    try { return `${this.name}: ${label}`; } catch { return label; }
  }
}
