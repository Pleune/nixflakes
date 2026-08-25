# ROS 2 Workspace Overview Skill

Automatically analyze ROS 2 workspaces to understand package architecture, dependencies, nodes, and launch configurations.

## What It Does

1. **Discovers all packages** in a ROS 2 workspace
2. **Extracts metadata** from `package.xml` files
3. **Finds nodes** by scanning Python and C++ source code
4. **Lists launch files** for each package
5. **Builds dependency graph** to determine package importance
6. **Generates overview** with prioritized packages and development instructions

## When to Use

- Starting work on an unfamiliar ROS 2 codebase
- Need to understand package architecture and relationships
- Want to know what nodes exist and how to run them
- Looking for entry points to launch/debug specific components
- Documenting a ROS 2 system

## Example Usage

```bash
# From a ROS 2 workspace
cd ~/ros2_ws
pi
> analyze the ros2 workspace
```

The agent will:
1. Run the `analyze.js` script to extract package data
2. Build a dependency graph
3. Sort packages by importance (most dependencies first)
4. Generate a markdown overview with:
   - Package purpose and description
   - List of nodes with their roles
   - Dependencies and why they're needed
   - Launch file descriptions
   - Commands to run/debug each node

## Script Output Format

The `analyze.js` script outputs JSON:

```json
{
  "workspace": "/path/to/ros2_ws",
  "packages": [
    {
      "name": "my_package",
      "path": "/path/to/ros2_ws/src/my_package",
      "description": "Package description",
      "version": "1.0.0",
      "maintainer": "Name",
      "license": "Apache-2.0",
      "dependencies": {
        "build": ["rclcpp", "std_msgs"],
        "exec": ["rclcpp", "std_msgs"],
        "test": ["ament_cmake_gtest"]
      },
      "launchFiles": ["demo.launch.py"],
      "nodes": [
        {
          "name": "my_node",
          "type": "python",
          "source": "my_node.py"
        }
      ]
    }
  ]
}
```

## Node Detection

### Python Nodes
- Parses `setup.py` for `console_scripts` entry points
- Scans `.py` files for `Node('node_name')` constructor calls

### C++ Nodes
- Parses `CMakeLists.txt` for `add_executable()` declarations
- Scans `.cpp/.cc/.cxx` files for `rclcpp::Node("node_name")` constructors

### Launch Files
- Finds `*.launch.py`, `*.launch.xml`, `*.launch.yaml` files in `launch/` directories

## Tips for Analysis

- **Core packages** have many dependents (infrastructure/common code)
- **Leaf packages** have few/no dependents (application-specific)
- **Entry points** usually have launch files
- **Interface packages** often only define messages/services/actions
- Follow dependency chains to understand data flow between nodes
