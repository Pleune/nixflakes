# ROS 2 Workspace Overview

Generate a comprehensive, prioritized overview of all ROS 2 packages in a workspace, including nodes, dependencies, and launch instructions.

## Quick Start

```bash
# From workspace root (where src/ directory exists)
./analyze.js

# Or specify custom workspace path
./analyze.js /path/to/ros2_ws
```

The script outputs JSON with package metadata, dependencies, launch files, and detected nodes.

## Workflow

1. **Extract package data**: Run `analyze.js` to get structured JSON
2. **Build dependency graph**: Count how many packages depend on each package (dependents count = importance)
3. **Sort by importance**: Packages with most dependents first, then alphabetically
4. **For each package, document**:
   - **Purpose**: 1-2 sentence description (from package.xml + node analysis)
   - **Nodes**: List each node/executable with brief purpose
   - **Interactions**: Which packages it depends on and why
   - **Launch & Debug**: How to run nodes individually or via launch files

## Output Format

```markdown
# ROS 2 Workspace Overview

## Package Dependency Summary
- Total packages: N
- [Dependency graph insights]

## Packages (by importance)

### 1. package_name (X dependents)

**Purpose**: [What this package does]

**Nodes**:
- `node_name`: [What it does]
- `another_node`: [What it does]

**Dependencies**:
- `dep_package`: [Why needed - e.g., "Uses X message types"]

**Launch Files**:
- `launch_file.py`: [What it launches]

**Run & Debug**:
```bash
# Run individual node
ros2 run package_name node_name [--ros-args -p param:=value]

# Launch full system
ros2 launch package_name launch_file.py

# Debug with logging
ros2 run package_name node_name --ros-args --log-level debug
```

[Repeat for each package...]
```

## Node Detection Patterns

The script scans for:

**Python nodes**:
- `Node('node_name')` constructor calls
- `entry_points` in `setup.py`

**C++ nodes**:
- `rclcpp::Node("node_name")` constructors
- Executables in `CMakeLists.txt`

**Launch files**:
- `*.launch.py`, `*.launch.xml`, `*.launch.yaml` in `launch/` directories

## Tips

- **Identify core packages**: Packages with many dependents are architectural foundations
- **Find entry points**: Packages with launch files are often the "runnable" components
- **Trace interactions**: Follow dependency chains to understand data flow
- **Dev workflow**: Focus on individual node commands for iteration speed
- **Integration testing**: Use launch files that bring up multiple nodes

## When Dependencies Unclear

If `package.xml` dependencies don't explain usage:
1. Search for `import` statements (Python) or `#include` (C++)
2. Look for message/service types used in node code
3. Check for action definitions or custom interfaces
