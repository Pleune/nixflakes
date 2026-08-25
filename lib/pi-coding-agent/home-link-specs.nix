{ inventory }:
{
  fileEntries = builtins.filter (entry: entry.kind == "file") inventory.managedEntries;
  dirEntries = builtins.filter (entry: entry.kind == "dir") inventory.managedEntries;
}
