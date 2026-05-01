# NXS — C#

Zero-copy `.nxb` reader and direct-to-buffer writer for C# (.NET 8). Uses only BCL types; no NuGet dependencies.

## Requirements

- .NET 8 SDK (`dotnet` CLI)

## Build & Test

```bash
cd csharp
dotnet run -- ../js/fixtures          # smoke tests
dotnet run -c Release -- ../js/fixtures ../js/fixtures  # pass dir twice to also bench
```

## Read a file

```csharp
using Nxs;

byte[] data = File.ReadAllBytes("data.nxb");
var reader  = new NxsReader(data);

Console.WriteLine(reader.RecordCount);   // int
Console.WriteLine(string.Join(", ", reader.Keys));

var obj = reader.Record(42);
long   id     = obj.GetI64("id");
double score  = obj.GetF64("score");
bool   active = obj.GetBool("active");
string name   = obj.GetStr("username");

// Slot optimisation
int    scoreSlot = reader.Slot("score");
double s         = obj.GetF64BySlot(scoreSlot);

// Bulk reducers
double  sum  = reader.SumF64("score");
long    sumi = reader.SumI64("id");
double? mn   = reader.MinF64("score");
double? mx   = reader.MaxF64("score");
```

## Write a file

```csharp
using Nxs;

var schema = new NxsSchema(["id", "username", "score", "active"]);
var w = new NxsWriter(schema);

w.BeginObject();
w.WriteI64(0, 42L);
w.WriteStr(1, "alice");
w.WriteF64(2, 9.5);
w.WriteBool(3, true);
w.EndObject();

byte[] bytes = w.Finish();

// Convenience: write from a list of dictionaries
byte[] bytes2 = NxsWriter.FromRecords(
    ["id", "username", "score"],
    [new Dictionary<string, object?> { ["id"] = 1L, ["username"] = "bob", ["score"] = 8.2 }]
);
```

## Files

| File | Purpose |
| :--- | :--- |
| `NxsReader.cs` | Reader (`NxsReader`, `NxsObject`) |
| `NxsWriter.cs` | Writer (`NxsSchema`, `NxsWriter`) |

---

For the format specification see [`SPEC.md`](../SPEC.md). For cross-language examples see [`GETTING_STARTED.md`](../GETTING_STARTED.md).
