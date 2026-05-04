#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// Parse command line arguments
const workspacePath = process.argv[2] || process.cwd();
const srcPath = path.join(workspacePath, 'src');

if (!fs.existsSync(srcPath)) {
  console.error(`Error: No 'src' directory found in ${workspacePath}`);
  console.error('Usage: analyze.js [workspace_path]');
  process.exit(1);
}

// Find all package.xml files
function findPackages(dir) {
  const packages = [];
  
  function walk(currentPath) {
    const entries = fs.readdirSync(currentPath, { withFileTypes: true });
    
    for (const entry of entries) {
      const fullPath = path.join(currentPath, entry.name);
      
      if (entry.isDirectory()) {
        // Skip common ignore directories
        if (['build', 'install', 'log', '.git', 'node_modules'].includes(entry.name)) {
          continue;
        }
        walk(fullPath);
      } else if (entry.name === 'package.xml') {
        packages.push(path.dirname(fullPath));
      }
    }
  }
  
  walk(dir);
  return packages;
}

// Parse package.xml
function parsePackageXml(packagePath) {
  const xmlPath = path.join(packagePath, 'package.xml');
  const content = fs.readFileSync(xmlPath, 'utf-8');
  
  const name = (content.match(/<name>(.*?)<\/name>/) || [])[1] || '';
  const description = (content.match(/<description>(.*?)<\/description>/) || [])[1] || '';
  const version = (content.match(/<version>(.*?)<\/version>/) || [])[1] || '';
  const maintainer = (content.match(/<maintainer.*?>(.*?)<\/maintainer>/) || [])[1] || '';
  const license = (content.match(/<license>(.*?)<\/license>/) || [])[1] || '';
  
  // Extract dependencies
  const buildDepends = [...content.matchAll(/<build_depend>(.*?)<\/build_depend>/g)].map(m => m[1]);
  const execDepends = [...content.matchAll(/<exec_depend>(.*?)<\/exec_depend>/g)].map(m => m[1]);
  const depend = [...content.matchAll(/<depend>(.*?)<\/depend>/g)].map(m => m[1]);
  const testDepends = [...content.matchAll(/<test_depend>(.*?)<\/test_depend>/g)].map(m => m[1]);
  
  return {
    name,
    description,
    version,
    maintainer,
    license,
    dependencies: {
      build: [...new Set([...buildDepends, ...depend])],
      exec: [...new Set([...execDepends, ...depend])],
      test: testDepends
    }
  };
}

// Find launch files
function findLaunchFiles(packagePath) {
  const launchFiles = [];
  const launchDir = path.join(packagePath, 'launch');
  
  if (!fs.existsSync(launchDir)) {
    return launchFiles;
  }
  
  const files = fs.readdirSync(launchDir);
  for (const file of files) {
    if (file.match(/\.(launch\.py|launch\.xml|launch\.yaml|launch\.yml)$/)) {
      launchFiles.push(file);
    }
  }
  
  return launchFiles;
}

// Find Python nodes
function findPythonNodes(packagePath, packageName) {
  const nodes = [];
  
  // Check setup.py for entry points
  const setupPy = path.join(packagePath, 'setup.py');
  if (fs.existsSync(setupPy)) {
    const content = fs.readFileSync(setupPy, 'utf-8');
    const entryPointsMatch = content.match(/entry_points\s*=\s*{([^}]+)}/s);
    
    if (entryPointsMatch) {
      const consoleScripts = entryPointsMatch[1].match(/'console_scripts':\s*\[(.*?)\]/s);
      if (consoleScripts) {
        const scripts = [...consoleScripts[1].matchAll(/'([^']+)\s*=\s*([^']+)'/g)];
        for (const [, nodeName, target] of scripts) {
          nodes.push({ name: nodeName.trim(), type: 'python', source: 'setup.py' });
        }
      }
    }
  }
  
  // Scan Python files for Node constructors
  const pythonDir = path.join(packagePath, packageName);
  if (fs.existsSync(pythonDir)) {
    function scanPyFiles(dir) {
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory() && entry.name !== '__pycache__') {
          scanPyFiles(fullPath);
        } else if (entry.name.endsWith('.py')) {
          const content = fs.readFileSync(fullPath, 'utf-8');
          const nodeMatches = [...content.matchAll(/Node\s*\(\s*['"]([^'"]+)['"]/g)];
          for (const [, nodeName] of nodeMatches) {
            if (!nodes.find(n => n.name === nodeName)) {
              nodes.push({ name: nodeName, type: 'python', source: path.basename(fullPath) });
            }
          }
        }
      }
    }
    scanPyFiles(pythonDir);
  }
  
  return nodes;
}

// Find C++ nodes
function findCppNodes(packagePath) {
  const nodes = [];
  
  // Check CMakeLists.txt for executables
  const cmakePath = path.join(packagePath, 'CMakeLists.txt');
  if (fs.existsSync(cmakePath)) {
    const content = fs.readFileSync(cmakePath, 'utf-8');
    const exeMatches = [...content.matchAll(/add_executable\s*\(\s*(\w+)/g)];
    for (const [, exeName] of exeMatches) {
      nodes.push({ name: exeName, type: 'cpp', source: 'CMakeLists.txt' });
    }
  }
  
  // Scan C++ files for rclcpp::Node constructors
  const srcDir = path.join(packagePath, 'src');
  if (fs.existsSync(srcDir)) {
    function scanCppFiles(dir) {
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          scanCppFiles(fullPath);
        } else if (entry.name.match(/\.(cpp|cc|cxx)$/)) {
          const content = fs.readFileSync(fullPath, 'utf-8');
          const nodeMatches = [...content.matchAll(/rclcpp::Node\s*\(\s*"([^"]+)"/g)];
          for (const [, nodeName] of nodeMatches) {
            if (!nodes.find(n => n.name === nodeName)) {
              nodes.push({ name: nodeName, type: 'cpp', source: path.basename(fullPath) });
            }
          }
        }
      }
    }
    scanCppFiles(srcDir);
  }
  
  return nodes;
}

// Analyze workspace
console.error('Analyzing ROS 2 workspace...');
const packagePaths = findPackages(srcPath);
console.error(`Found ${packagePaths.length} packages\n`);

const packages = [];

for (const packagePath of packagePaths) {
  const metadata = parsePackageXml(packagePath);
  const launchFiles = findLaunchFiles(packagePath);
  const pythonNodes = findPythonNodes(packagePath, metadata.name);
  const cppNodes = findCppNodes(packagePath);
  
  packages.push({
    name: metadata.name,
    path: packagePath,
    description: metadata.description,
    version: metadata.version,
    maintainer: metadata.maintainer,
    license: metadata.license,
    dependencies: metadata.dependencies,
    launchFiles,
    nodes: [...pythonNodes, ...cppNodes]
  });
}

// Output JSON
console.log(JSON.stringify({ workspace: workspacePath, packages }, null, 2));
