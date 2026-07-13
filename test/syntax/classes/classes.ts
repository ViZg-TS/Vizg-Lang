export class Derived extends Base {
  public name: string = "item";
  protected static count: number;
  constructor(name: string) { super(name); this.name = name; }
  private update(value: string): boolean { this.name = value; return true; }
}
let Anonymous = class extends Derived { method() { return super.method(); } };
