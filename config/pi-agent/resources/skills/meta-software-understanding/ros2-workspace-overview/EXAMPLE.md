# Example Analysis Output

This shows what the agent generates after running the skill on a typical ROS 2 workspace.

## Example Workspace Structure

```
ros2_ws/
└── src/
    ├── sensor_interfaces/
    │   └── package.xml (message definitions)
    ├── sensor_driver/
    │   ├── package.xml
    │   ├── sensor_driver/
    │   │   └── lidar_node.py
    │   └── launch/
    │       └── sensor.launch.py
    └── robot_controller/
        ├── package.xml
        ├── src/
        │   └── controller_node.cpp
        └── launch/
            └── control.launch.py
```

## Generated Overview

```markdown
# ROS 2 Workspace Overview

## Package Dependency Summary
- Total packages: 3
- Core packages (3+ dependents): sensor_interfaces
- Application packages (0 dependents): robot_controller

## Packages (by importance)

### 1. sensor_interfaces (2 dependents)

**Purpose**: Defines custom message types for sensor data communication across the robot system.

**Nodes**: None (interface package)

**Dependencies**:
- `std_msgs`: Standard ROS message types
- `geometry_msgs`: Pose and transform messages

**Launch Files**: None

**Run & Debug**:
```bash
# Interface package - used by other packages
# To inspect messages:
ros2 interface show sensor_interfaces/msg/LidarScan
```

---

### 2. sensor_driver (1 dependent)

**Purpose**: Hardware drivers for robot sensors including LiDAR and IMU.

**Nodes**:
- `lidar_node`: Publishes LiDAR scan data at 10Hz on `/scan` topic

**Dependencies**:
- `rclpy`: Python ROS client library
- `sensor_interfaces`: Custom message definitions for sensor data

**Launch Files**:
- `sensor.launch.py`: Launches all sensor drivers with configured parameters

**Run & Debug**:
```bash
# Run LiDAR node alone
ros2 run sensor_driver lidar_node --ros-args -p port:=/dev/ttyUSB0

# Launch all sensors
ros2 launch sensor_driver sensor.launch.py

# Debug with verbose logging
ros2 run sensor_driver lidar_node --ros-args --log-level debug

# Monitor published data
ros2 topic echo /scan
```

---

### 3. robot_controller (0 dependents)

**Purpose**: High-level motion control and navigation logic for the robot platform.

**Nodes**:
- `controller_node`: Main control loop that subscribes to sensor data and publishes velocity commands

**Dependencies**:
- `rclcpp`: C++ ROS client library
- `sensor_interfaces`: Receives sensor data messages
- `geometry_msgs`: Publishes Twist commands

**Launch Files**:
- `control.launch.py`: Starts controller with default PID parameters

**Run & Debug**:
```bash
# Run controller (requires sensor_driver to be running)
ros2 run robot_controller controller_node

# Launch with custom parameters
ros2 launch robot_controller control.launch.py max_speed:=0.5

# Debug mode
ros2 run robot_controller controller_node --ros-args --log-level debug

# Monitor commands
ros2 topic echo /cmd_vel
```

---

## Development Workflow

**Quick iteration on single node:**
```bash
ros2 run <package> <node> --ros-args --log-level debug
```

**Integration testing:**
```bash
ros2 launch <package> <launch_file>
```

**Visualize node graph:**
```bash
rqt_graph
```
```

## Notes

- The agent orders packages by "importance" (number of dependents)
- Each package gets context about its role in the system
- Run/debug commands are tailored to each node
- Dependencies are explained with usage context
