type Primitive = string | number;
type Combined = readonly string[] & { id: number; name?: string };
type Generic = Array<string>;
type Grouped = (string | number)[];
type Callback = (value: Primitive, flags?: [boolean, number]) => string[];
interface Base { id: number; }
interface Entity extends Base, Named { name: string; run?: (input: Primitive) => boolean; }
let callback: Callback;
type Keys = keyof Entity;
type Name = Entity['name'];
type Item = Array<string>[number][];
type CallbackQuery = typeof callback;
