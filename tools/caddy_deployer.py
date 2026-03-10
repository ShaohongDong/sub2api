#!/usr/bin/env python3
"""
Caddy Deployment Script
完善的Caddy部署和管理工具，支持自动安装、配置生成、服务管理等功能
"""

import argparse
import csv
import json
import logging
import os
import platform
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, List, Tuple


class CaddyDeployer:
    """Caddy部署和管理类"""
    
    def __init__(self):
        self.system = platform.system().lower()
        self.arch = self._get_architecture()
        self.caddy_path = self._get_caddy_path()
        self.config_dir = Path.home() / ".caddy"
        self.config_file = self.config_dir / "Caddyfile"
        self.pid_file = self.config_dir / "caddy.pid"
        self.log_file = self.config_dir / "caddy.log"
        
        # 创建配置目录
        self.config_dir.mkdir(exist_ok=True)
        
        # 设置日志
        self._setup_logging()
        
    def _setup_logging(self):
        """设置日志配置"""
        log_format = '%(asctime)s - %(levelname)s - %(message)s'
        logging.basicConfig(
            level=logging.INFO,
            format=log_format,
            handlers=[
                logging.StreamHandler(sys.stdout),
                logging.FileHandler(self.log_file, encoding='utf-8')
            ]
        )
        self.logger = logging.getLogger(__name__)
        
    def _get_architecture(self) -> str:
        """获取系统架构"""
        arch_map = {
            'AMD64': 'amd64',
            'x86_64': 'amd64',
            'x86': '386',
            'i386': '386',
            'ARM64': 'arm64',
            'aarch64': 'arm64'
        }
        machine = platform.machine().upper()
        return arch_map.get(machine, 'amd64')
        
    def _get_caddy_path(self) -> Path:
        """获取Caddy可执行文件路径"""
        if self.system == 'windows':
            return Path.cwd() / "caddy.exe"
        else:
            # 优先检查系统路径
            caddy_in_path = shutil.which('caddy')
            if caddy_in_path:
                return Path(caddy_in_path)
            return Path.cwd() / "caddy"

    def _normalize_path(self, path: Optional[str]) -> str:
        """规范化路径，便于跨平台比较"""
        if not path:
            return ""
        cleaned = path.strip().strip('"').strip("'")
        return os.path.normcase(os.path.normpath(cleaned))

    def _strip_scheme(self, address: str) -> str:
        """移除地址中的协议前缀"""
        if '://' not in address:
            return address
        parsed = urllib.parse.urlparse(address)
        return parsed.netloc or parsed.path

    def _is_local_domain(self, domain: str) -> bool:
        """判断是否为本地开发地址"""
        normalized = self._strip_scheme(domain)
        host = normalized.split(':', 1)[0]
        return host in ['localhost', '0.0.0.0'] or host.startswith('127.')

    def _format_site_address(self, domain: str, enable_ssl: bool) -> str:
        """根据SSL设置格式化站点地址"""
        normalized = self._strip_scheme(domain)
        scheme = 'https' if enable_ssl else 'http'
        return f"{scheme}://{normalized}"

    def _read_pid_file(self) -> Optional[int]:
        """读取PID文件中的进程ID"""
        try:
            if not self.pid_file.exists():
                return None
            with open(self.pid_file, 'r', encoding='utf-8') as f:
                return int(f.read().strip())
        except Exception:
            return None

    def _remove_pid_file(self) -> None:
        """删除PID文件"""
        self.pid_file.unlink(missing_ok=True)

    def _get_process_info(self, pid: int) -> Optional[Dict[str, str]]:
        """获取进程的可执行文件和命令行信息"""
        try:
            if self.system == 'windows':
                command = (
                    f'$p = Get-CimInstance Win32_Process -Filter "ProcessId = {pid}" '
                    '-ErrorAction SilentlyContinue; '
                    'if ($p) { '
                    '$p | Select-Object ExecutablePath, CommandLine, Name | '
                    'ConvertTo-Json -Compress }'
                )
                result = subprocess.run(
                    ['powershell', '-NoProfile', '-Command', command],
                    capture_output=True,
                    text=True
                )
                if result.returncode != 0 or not result.stdout.strip():
                    return None

                data = json.loads(result.stdout)
                return {
                    'pid': str(pid),
                    'name': data.get('Name') or '',
                    'executable_path': data.get('ExecutablePath') or '',
                    'command_line': data.get('CommandLine') or ''
                }

            proc_dir = Path('/proc') / str(pid)
            executable_path = ''
            command_line = ''
            name = ''

            try:
                executable_path = os.readlink(proc_dir / 'exe')
            except Exception:
                executable_path = ''

            try:
                cmdline_path = proc_dir / 'cmdline'
                command_line = cmdline_path.read_text(encoding='utf-8', errors='ignore').replace('\x00', ' ').strip()
            except Exception:
                command_line = ''

            if not command_line:
                result = subprocess.run(
                    ['ps', '-p', str(pid), '-o', 'command='],
                    capture_output=True,
                    text=True
                )
                command_line = result.stdout.strip()

            result = subprocess.run(
                ['ps', '-p', str(pid), '-o', 'comm='],
                capture_output=True,
                text=True
            )
            name = result.stdout.strip()

            if not executable_path and not command_line and not name:
                return None

            return {
                'pid': str(pid),
                'name': name,
                'executable_path': executable_path,
                'command_line': command_line
            }
        except Exception:
            return None

    def _is_caddy_process(self, process_info: Optional[Dict[str, str]]) -> bool:
        """判断进程是否为Caddy"""
        if not process_info:
            return False

        expected_path = self._normalize_path(str(self.caddy_path))
        executable_path = self._normalize_path(process_info.get('executable_path'))
        name = (process_info.get('name') or '').lower()
        command_line = process_info.get('command_line') or ''

        if executable_path and executable_path == expected_path:
            return True

        binary_names = {'caddy', 'caddy.exe'}
        if Path(name).name in binary_names:
            if not executable_path:
                return True
            return executable_path.endswith(os.path.normcase('caddy')) or executable_path.endswith(os.path.normcase('caddy.exe'))

        normalized_command = self._normalize_path(command_line)
        return bool(expected_path and expected_path in normalized_command)

    def _matches_managed_process(self, process_info: Optional[Dict[str, str]]) -> bool:
        """判断进程是否为当前工具启动的受管Caddy实例"""
        if not self._is_caddy_process(process_info):
            return False

        command_line = process_info.get('command_line') or ''
        managed_markers = [
            ('--config', str(self.config_file)),
            ('--pidfile', str(self.pid_file))
        ]
        return any(flag in command_line and marker in command_line for flag, marker in managed_markers)

    def _get_managed_pid(self, remove_stale: bool = True) -> Optional[int]:
        """返回当前工具管理的Caddy进程PID"""
        pid = self._read_pid_file()
        if pid is None:
            return None

        process_info = self._get_process_info(pid)
        if self._matches_managed_process(process_info):
            return pid

        if remove_stale:
            self.logger.warning(f"检测到无效或过期的PID文件，忽略 PID {pid}")
            self._remove_pid_file()
        return None

    def _terminate_process(self, pid: int) -> bool:
        """终止指定PID的进程"""
        try:
            if self.system == 'windows':
                result = subprocess.run(
                    ['taskkill', '/F', '/T', '/PID', str(pid)],
                    capture_output=True,
                    text=True
                )
                return result.returncode == 0

            try:
                os.kill(pid, 15)  # SIGTERM
            except ProcessLookupError:
                return True

            time.sleep(2)
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True

            os.kill(pid, 9)  # SIGKILL
            return True
        except ProcessLookupError:
            return True
        except Exception:
            return False
            
    def check_dependencies(self) -> bool:
        """检查系统依赖"""
        self.logger.info("检查系统依赖...")
        
        # 检查Python版本
        if sys.version_info < (3, 6):
            self.logger.error("需要Python 3.6或更高版本")
            return False
            
        # 检查网络连接
        try:
            urllib.request.urlopen('https://api.github.com', timeout=5)
        except Exception as e:
            self.logger.warning(f"网络连接检查失败: {e}")
            
        self.logger.info("系统依赖检查完成")
        return True
        
    def install_caddy(self, force: bool = False) -> bool:
        """安装或更新Caddy"""
        if self.caddy_path.exists() and not force:
            self.logger.info(f"Caddy已存在: {self.caddy_path}")
            return True
            
        self.logger.info("开始安装Caddy...")
        
        try:
            # 获取最新版本信息
            version_url = "https://api.github.com/repos/caddyserver/caddy/releases/latest"
            with urllib.request.urlopen(version_url, timeout=10) as response:
                release_info = json.loads(response.read().decode())
                version = release_info['tag_name'].lstrip('v')
                
            self.logger.info(f"最新版本: {version}")
            
            # 构建下载URL
            if self.system == 'windows':
                filename = f"caddy_{version}_windows_{self.arch}.zip"
            elif self.system == 'linux':
                filename = f"caddy_{version}_linux_{self.arch}.tar.gz"
            elif self.system == 'darwin':
                filename = f"caddy_{version}_mac_{self.arch}.tar.gz"
            else:
                raise Exception(f"不支持的操作系统: {self.system}")
                
            download_url = f"https://github.com/caddyserver/caddy/releases/download/v{version}/{filename}"
            
            # 下载文件
            self.logger.info(f"下载Caddy: {download_url}")
            with tempfile.TemporaryDirectory() as temp_dir:
                temp_file = Path(temp_dir) / filename
                
                with urllib.request.urlopen(download_url, timeout=30) as response:
                    with open(temp_file, 'wb') as f:
                        shutil.copyfileobj(response, f)
                        
                # 解压文件
                self.logger.info("解压Caddy...")
                if filename.endswith('.zip'):
                    with zipfile.ZipFile(temp_file, 'r') as zip_ref:
                        zip_ref.extract('caddy.exe', temp_dir)
                        source_path = Path(temp_dir) / 'caddy.exe'
                else:
                    # tar.gz文件
                    subprocess.run(['tar', '-xzf', str(temp_file), '-C', temp_dir], 
                                 check=True, capture_output=True)
                    source_path = Path(temp_dir) / 'caddy'
                
                # 移动到目标位置
                shutil.move(str(source_path), str(self.caddy_path))
                
            # 设置执行权限 (Unix系统)
            if self.system != 'windows':
                os.chmod(self.caddy_path, 0o755)
                
            self.logger.info(f"Caddy安装成功: {self.caddy_path}")
            return True
            
        except Exception as e:
            self.logger.error(f"Caddy安装失败: {e}")
            return False
            
    def generate_config(self, domain: str, backend_port: Optional[int], 
                       backend_host: str = "127.0.0.1",
                       enable_ssl: bool = False,
                       custom_config: Optional[str] = None) -> bool:
        """生成Caddy配置文件"""
        try:
            self.logger.info(f"生成配置文件: {self.config_file}")
            
            if custom_config:
                # 使用自定义配置
                config_content = custom_config
            else:
                # 生成标准配置
                is_local = self._is_local_domain(domain)
                site_address = self._format_site_address(domain, enable_ssl)
                x_frame_options = "SAMEORIGIN" if is_local else "DENY"
                hsts_header = ""
                if enable_ssl:
                    hsts_header = '        Strict-Transport-Security "max-age=31536000; includeSubDomains"\n'

                tls_block = ""
                if enable_ssl and is_local:
                    tls_block = "\n    tls internal"

                roll_keep = 3 if is_local else 5

                config_content = f"""{site_address} {{
    # 静态资源长期缓存
    @static {{
        path /assets/*
        path /logo.png
        path /favicon.ico
    }}
    header @static {{
        Cache-Control "public, max-age=31536000, immutable"
        -Pragma
        -Expires
    }}

    # 响应压缩
    encode {{
        zstd
        gzip 6
    }}

    reverse_proxy {backend_host}:{backend_port} {{
        # 支持流式响应（SSE）
        flush_interval -1

        # 超时设置
        transport http {{
            read_timeout 300s
            write_timeout 300s
            dial_timeout 30s
        }}
    }}

    # 安全头部
    header {{
{hsts_header}        X-Frame-Options "{x_frame_options}"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }}

{tls_block}

    # 访问日志
    log {{
        output file {self.config_dir}/access.log {{
            roll_size 100mb
            roll_keep {roll_keep}
        }}
    }}
}}"""
            
            # 写入配置文件
            with open(self.config_file, 'w', encoding='utf-8') as f:
                f.write(config_content)
                
            self.logger.info("配置文件生成成功")
            return True
            
        except Exception as e:
            self.logger.error(f"配置文件生成失败: {e}")
            return False
            
    def validate_config(self) -> bool:
        """验证配置文件"""
        try:
            if not self.caddy_path.exists():
                return False
                
            if not self.config_file.exists():
                return False
                
            result = subprocess.run([
                str(self.caddy_path), 'validate', 
                '--config', str(self.config_file)
            ], capture_output=True, text=True, timeout=10)
            
            if result.returncode == 0:
                self.logger.info("配置文件验证通过")
                return True
            else:
                self.logger.error(f"配置文件验证失败: {result.stderr}")
                return False
                
        except Exception:
            return False
            
    def deploy(self) -> bool:
        """部署Caddy服务"""
        try:
            self.logger.info("开始部署Caddy服务...")
            
            # 检查端口冲突
            conflicts = self._check_port_conflicts()
            if conflicts['admin_port'] or conflicts['listening_ports']:
                self.logger.warning("检测到端口冲突:")
                if conflicts['admin_port']:
                    self.logger.warning(f"  管理端口 2019 被占用: {conflicts['admin_port']}")
                for port_conflict in conflicts['listening_ports']:
                    self.logger.warning(f"  端口 {port_conflict['port']} 被占用: {port_conflict['process']}")

                managed_pid = self._get_managed_pid()
                if managed_pid is not None:
                    self.logger.info(f"检测到受管Caddy实例正在运行 (PID: {managed_pid})，先停止后重新部署")
                    if not self.undeploy():
                        return False
                    time.sleep(2)

                    conflicts = self._check_port_conflicts()
                    if conflicts['admin_port'] or conflicts['listening_ports']:
                        self.logger.error("停止受管实例后端口仍被占用，请手动处理冲突后重试")
                        return False
                else:
                    caddy_processes = self._get_running_caddy_processes()
                    if caddy_processes:
                        self.logger.warning("检测到非受管Caddy进程占用端口，已停止自动清理以避免误杀:")
                        for process in caddy_processes:
                            self.logger.warning(
                                f"  PID {process['pid']} ({process['name']}): {process.get('command_line') or 'unknown'}"
                            )
                    else:
                        self.logger.warning("检测到非Caddy进程占用所需端口")

                    self.logger.info("请停止冲突进程或调整监听端口后重试部署")
                    return False
            
            # 检查是否已经运行
            if self.is_running():
                self.logger.warning("Caddy服务已在运行，先停止服务")
                self.undeploy()
                time.sleep(2)
                
            # 启动Caddy
            cmd = [
                str(self.caddy_path), 'run',
                '--config', str(self.config_file),
                '--pidfile', str(self.pid_file)
            ]
            
            self.logger.info(f"启动命令: {' '.join(cmd)}")
            
            # 后台运行
            if self.system == 'windows':
                # Windows使用CREATE_NEW_PROCESS_GROUP
                process = subprocess.Popen(
                    cmd,
                    stdout=open(self.log_file, 'a'),
                    stderr=subprocess.STDOUT,
                    creationflags=subprocess.CREATE_NEW_PROCESS_GROUP
                )
            else:
                # Unix系统
                process = subprocess.Popen(
                    cmd,
                    stdout=open(self.log_file, 'a'),
                    stderr=subprocess.STDOUT,
                    preexec_fn=os.setsid
                )
            
            # 保存PID
            with open(self.pid_file, 'w') as f:
                f.write(str(process.pid))
                
            # 等待启动并检查状态
            self.logger.info("等待Caddy启动...")
            max_wait = 10  # 最大等待10秒
            for i in range(max_wait):
                time.sleep(1)
                if self._check_pid_file_process():
                    self.logger.info(f"Caddy服务启动成功 (PID: {process.pid})")
                    return True
                    
                # 检查日志中的错误信息
                error_info = self._check_startup_errors()
                if error_info:
                    self.logger.error(f"Caddy启动失败: {error_info}")
                    self._provide_error_solution(error_info)
                    return False
                    
            # 超时仍未启动成功
            self.logger.error(f"Caddy服务启动超时 ({max_wait}秒)")
            recent_logs = self._get_recent_logs(10)
            if recent_logs:
                self.logger.error("最近的日志:")
                for log in recent_logs[-5:]:  # 只显示最后5行
                    self.logger.error(f"  {log}")
            return False
                
        except Exception as e:
            self.logger.error(f"部署失败: {e}")
            return False
            
    def undeploy(self) -> bool:
        """停止Caddy服务"""
        try:
            self.logger.info("停止Caddy服务...")
            
            managed_pid = self._get_managed_pid()
            if managed_pid is None:
                self.logger.info("Caddy服务未运行")
                return True

            self.logger.info(f"终止受管进程 PID: {managed_pid}")
            if not self._terminate_process(managed_pid):
                self.logger.error(f"终止受管进程失败: {managed_pid}")
                return False

            self._remove_pid_file()
            
            self.logger.info("Caddy服务停止成功")
            return True
            
        except Exception as e:
            self.logger.error(f"停止服务失败: {e}")
            return False
            
    def _cleanup_caddy_processes(self):
        """清理Caddy进程"""
        managed_pid = self._get_managed_pid()
        if managed_pid is None:
            return False
        return self._terminate_process(managed_pid)
            
    def is_running(self) -> bool:
        """检查Caddy服务是否运行"""
        return self._check_pid_file_process()
        
    def _check_pid_file_process(self) -> bool:
        """检查PID文件中的进程是否运行"""
        return self._get_managed_pid() is not None
            
    def _check_any_caddy_process(self) -> bool:
        """检查是否有任何Caddy进程在运行"""
        return bool(self._get_running_caddy_processes())
            
    def _get_running_caddy_processes(self) -> List[Dict]:
        """获取所有运行中的Caddy进程信息"""
        processes = []
        try:
            if self.system == 'windows':
                result = subprocess.run(
                    ['tasklist', '/FI', 'IMAGENAME eq caddy.exe', '/FO', 'CSV'],
                    capture_output=True,
                    text=True
                )
                reader = csv.reader(result.stdout.splitlines())
                next(reader, None)
                for row in reader:
                    if len(row) < 2:
                        continue
                    pid = row[1].strip()
                    if not pid.isdigit():
                        continue
                    process_info = self._get_process_info(int(pid))
                    if not self._is_caddy_process(process_info):
                        continue
                    processes.append({
                        'name': process_info.get('name') or row[0].strip(),
                        'pid': pid,
                        'command_line': process_info.get('command_line') or '',
                        'managed': self._matches_managed_process(process_info)
                    })
            else:
                result = subprocess.run(
                    ['pgrep', '-x', 'caddy'],
                    capture_output=True,
                    text=True
                )
                if result.returncode == 0:
                    pids = result.stdout.strip().split('\n')
                    for pid in pids:
                        if pid and pid.isdigit():
                            process_info = self._get_process_info(int(pid))
                            if not self._is_caddy_process(process_info):
                                continue
                            processes.append({
                                'name': process_info.get('name') or 'caddy',
                                'pid': pid.strip(),
                                'command_line': process_info.get('command_line') or '',
                                'managed': self._matches_managed_process(process_info)
                            })
        except Exception:
            pass
        return processes
        
    def _check_port_conflicts(self) -> Dict:
        """检查端口冲突"""
        conflicts = {
            'admin_port': None,  # Caddy管理端口 2019
            'listening_ports': []  # 配置文件中的监听端口
        }
        
        # 检查Caddy管理端口 2019
        if self._is_port_listening('127.0.0.1', 2019):
            conflicts['admin_port'] = self._get_process_using_port(2019)
            
        # 检查配置文件中的端口
        listening_ports = self._extract_listening_ports()
        for port in listening_ports:
            if self._is_port_listening('0.0.0.0', port) or self._is_port_listening('127.0.0.1', port):
                process_info = self._get_process_using_port(port)
                conflicts['listening_ports'].append({
                    'port': port,
                    'process': process_info
                })
                
        return conflicts
        
    def _get_process_using_port(self, port: int) -> Optional[str]:
        """获取使用特定端口的进程信息"""
        try:
            if self.system == 'windows':
                result = subprocess.run(['netstat', '-ano'], capture_output=True, text=True)
                for line in result.stdout.split('\n'):
                    if f':{port}' in line and 'LISTENING' in line:
                        parts = line.split()
                        if len(parts) >= 5:
                            pid = parts[-1]
                            # 获取进程名
                            proc_result = subprocess.run(['tasklist', '/FI', f'PID eq {pid}'],
                                                       capture_output=True, text=True)
                            return f"PID {pid} ({proc_result.stdout.split()[0] if proc_result.stdout else 'unknown'})"
            else:
                # Linux/Unix使用lsof或netstat
                try:
                    result = subprocess.run(['lsof', f'-i:{port}'], capture_output=True, text=True)
                    if result.returncode == 0:
                        lines = result.stdout.strip().split('\n')
                        if len(lines) > 1:  # 跳过标题行
                            parts = lines[1].split()
                            if len(parts) >= 2:
                                return f"{parts[0]} (PID {parts[1]})"
                except FileNotFoundError:
                    # 如果没有lsof，使用ss
                    result = subprocess.run(['ss', '-tlnp'], capture_output=True, text=True)
                    for line in result.stdout.split('\n'):
                        if f':{port}' in line and 'LISTEN' in line:
                            # 解析ss输出中的进程信息
                            if 'users:' in line:
                                proc_part = line.split('users:')[1].strip()
                                return proc_part
                            return "unknown process"
        except Exception:
            pass
        return None
        
    def _check_startup_errors(self) -> Optional[str]:
        """检查启动错误"""
        try:
            if not self.log_file.exists():
                return None
                
            # 读取最近的日志
            with open(self.log_file, 'r', encoding='utf-8') as f:
                lines = f.readlines()
                
            # 检查最近10行中的错误
            recent_lines = lines[-10:] if len(lines) >= 10 else lines
            for line in recent_lines:
                line = line.strip().lower()
                if 'error:' in line or 'failed' in line:
                    if 'address already in use' in line:
                        return "端口被占用"
                    elif 'bind' in line and 'address' in line:
                        return "端口绑定失败"
                    elif 'permission denied' in line:
                        return "权限不足"
                    elif 'config' in line:
                        return "配置文件错误"
                    else:
                        return line[:100]  # 返回前100个字符
                        
        except Exception:
            pass
        return None
        
    def _provide_error_solution(self, error_info: str) -> None:
        """提供错误解决方案"""
        if "端口被占用" in error_info or "端口绑定失败" in error_info:
            self.logger.info("解决方案:")
            self.logger.info("  1. 检查并停止其他Caddy进程: python caddy_deployer.py undeploy")
            self.logger.info("  2. 检查占用端口的进程: ss -tlnp | grep :2019")
            self.logger.info("  3. 修改配置使用不同端口")
        elif "权限不足" in error_info:
            self.logger.info("解决方案:")
            self.logger.info("  1. 使用sudo运行脚本 (如果需要绑定80/443端口)")
            self.logger.info("  2. 或修改配置使用非特权端口 (>1024)")
        elif "配置文件错误" in error_info:
            self.logger.info("解决方案:")
            self.logger.info("  1. 验证配置文件: caddy validate --config ~/.caddy/Caddyfile")
            self.logger.info("  2. 检查配置文件语法")
            
    def status(self) -> Dict:
        """获取服务状态"""
        managed_pid = self._get_managed_pid()
        running = managed_pid is not None
        status_info = {
            'running': running,
            'caddy_path': str(self.caddy_path),
            'config_file': str(self.config_file),
            'pid_file': str(self.pid_file),
            'log_file': str(self.log_file)
        }
        
        if running:
            status_info['pid'] = managed_pid
                
        return status_info
        
    def health_check(self, detailed: bool = False) -> Dict:
        """全面健康检查"""
        health_status = {
            'timestamp': datetime.now().isoformat(),
            'overall_status': 'unknown',
            'checks': {
                'process': self._check_process(),
                'config': self._check_config(),
                'ports': self._check_ports(),
                'frontend': self._check_frontend_connectivity(),
                'backend': self._check_backend_connectivity(),
                'ssl': self._check_ssl_status()
            }
        }
        
        # 计算整体状态
        all_checks_passed = all(
            check.get('status') == 'ok' 
            for check in health_status['checks'].values()
            if check.get('required', True)  # 只检查必需的项目
        )
        
        health_status['overall_status'] = 'healthy' if all_checks_passed else 'unhealthy'
        
        if detailed:
            health_status['logs'] = self._get_recent_logs(50)
            health_status['system_info'] = self._get_system_info()
        
        return health_status
        
    def _check_process(self) -> Dict:
        """检查Caddy进程状态"""
        try:
            if not self.is_running():
                return {
                    'status': 'error',
                    'message': 'Caddy进程未运行',
                    'required': True
                }
                
            pid = None
            if self.pid_file.exists():
                with open(self.pid_file, 'r') as f:
                    pid = int(f.read().strip())
                    
            return {
                'status': 'ok',
                'message': 'Caddy进程正常运行',
                'pid': pid,
                'required': True
            }
        except Exception as e:
            return {
                'status': 'error',
                'message': f'进程检查失败: {e}',
                'required': True
            }
            
    def _check_config(self) -> Dict:
        """检查配置文件状态"""
        try:
            if not self.config_file.exists():
                return {
                    'status': 'error',
                    'message': '配置文件不存在',
                    'required': True
                }
                
            # 检查配置文件是否有效
            if self.validate_config():
                return {
                    'status': 'ok',
                    'message': '配置文件有效',
                    'path': str(self.config_file),
                    'required': True
                }
            else:
                return {
                    'status': 'error',
                    'message': '配置文件验证失败',
                    'path': str(self.config_file),
                    'required': True
                }
        except Exception as e:
            return {
                'status': 'error',
                'message': f'配置检查失败: {e}',
                'required': True
            }
            
    def _check_ports(self) -> Dict:
        """检查端口监听状态"""
        try:
            listening_ports = []
            
            # 从配置文件解析监听端口
            ports_to_check = self._extract_listening_ports()
            
            for port in ports_to_check:
                if self._is_port_listening('127.0.0.1', port):
                    listening_ports.append(port)
                    
            if listening_ports:
                return {
                    'status': 'ok',
                    'message': f'端口监听正常: {listening_ports}',
                    'listening_ports': listening_ports,
                    'required': True
                }
            else:
                return {
                    'status': 'error',
                    'message': '没有检测到监听端口',
                    'required': True
                }
        except Exception as e:
            return {
                'status': 'error',
                'message': f'端口检查失败: {e}',
                'required': True
            }
            
    def _check_frontend_connectivity(self) -> Dict:
        """检查前端连通性"""
        try:
            # 从配置文件提取域名和端口
            endpoints = self._extract_frontend_endpoints()
            
            results = []
            for endpoint in endpoints:
                result = self._test_http_endpoint(endpoint)
                results.append(result)
                
            successful_tests = [r for r in results if r['success']]
            
            if successful_tests:
                return {
                    'status': 'ok',
                    'message': f'前端连接正常 ({len(successful_tests)}/{len(results)})',
                    'tests': results,
                    'required': True
                }
            else:
                return {
                    'status': 'error',
                    'message': '前端连接失败',
                    'tests': results,
                    'required': True
                }
        except Exception as e:
            return {
                'status': 'error',
                'message': f'前端连通性检查失败: {e}',
                'required': True
            }
            
    def _check_backend_connectivity(self) -> Dict:
        """检查后端服务连接"""
        try:
            # 从配置文件提取后端地址
            backends = self._extract_backend_endpoints()
            
            results = []
            for backend in backends:
                host, port = backend.split(':')
                success = self._test_backend_connection(host, int(port))
                results.append({
                    'backend': backend,
                    'success': success,
                    'message': '连接成功' if success else '连接失败'
                })
                
            successful_tests = [r for r in results if r['success']]
            
            if successful_tests:
                return {
                    'status': 'ok',
                    'message': f'后端连接正常 ({len(successful_tests)}/{len(results)})',
                    'tests': results,
                    'required': True
                }
            else:
                return {
                    'status': 'warning',
                    'message': '部分或全部后端连接失败',
                    'tests': results,
                    'required': False  # 后端可能暂时不可用
                }
        except Exception as e:
            return {
                'status': 'warning',
                'message': f'后端连通性检查失败: {e}',
                'required': False
            }
            
    def _check_ssl_status(self) -> Dict:
        """检查SSL证书状态"""
        try:
            # 从配置文件提取HTTPS端点
            https_endpoints = self._extract_https_endpoints()
            
            if not https_endpoints:
                return {
                    'status': 'info',
                    'message': '未配置HTTPS',
                    'required': False
                }
                
            results = []
            for endpoint in https_endpoints:
                cert_info = self._get_ssl_certificate_info(endpoint)
                results.append(cert_info)
                
            valid_certs = [r for r in results if r.get('valid', False)]
            
            if len(valid_certs) == len(results):
                return {
                    'status': 'ok',
                    'message': 'SSL证书状态正常',
                    'certificates': results,
                    'required': False
                }
            else:
                return {
                    'status': 'warning',
                    'message': '部分SSL证书存在问题',
                    'certificates': results,
                    'required': False
                }
        except Exception as e:
            return {
                'status': 'info',
                'message': f'SSL检查失败: {e}',
                'required': False
            }
            
    def _is_port_listening(self, host: str, port: int) -> bool:
        """检查端口是否监听"""
        try:
            with socket.create_connection((host, port), timeout=5):
                return True
        except (socket.error, ConnectionRefusedError, OSError):
            return False
            
    def _test_http_endpoint(self, endpoint: str) -> Dict:
        """测试HTTP端点"""
        try:
            req = urllib.request.Request(endpoint)
            req.add_header('User-Agent', 'CaddyDeployer-HealthCheck/1.0')
            
            start_time = time.time()
            with urllib.request.urlopen(req, timeout=10) as response:
                response_time = time.time() - start_time
                status_code = response.getcode()
                
                return {
                    'endpoint': endpoint,
                    'success': True,
                    'status_code': status_code,
                    'response_time': round(response_time * 1000, 2),  # ms
                    'message': f'响应正常 ({status_code})'
                }
        except urllib.error.HTTPError as e:
            return {
                'endpoint': endpoint,
                'success': False,
                'status_code': e.code,
                'message': f'HTTP错误: {e.code}'
            }
        except Exception as e:
            return {
                'endpoint': endpoint,
                'success': False,
                'message': f'连接失败: {e}'
            }
            
    def _test_backend_connection(self, host: str, port: int) -> bool:
        """测试后端连接"""
        try:
            with socket.create_connection((host, port), timeout=5):
                return True
        except Exception:
            return False
            
    def _get_ssl_certificate_info(self, endpoint: str) -> Dict:
        """获取SSL证书信息"""
        try:
            # 解析URL
            parsed = urllib.parse.urlparse(endpoint)
            hostname = parsed.hostname
            port = parsed.port or 443
            
            # 获取证书
            context = ssl.create_default_context()
            with socket.create_connection((hostname, port), timeout=10) as sock:
                with context.wrap_socket(sock, server_hostname=hostname) as ssock:
                    cert = ssock.getpeercert()
                    
            # 解析证书信息
            not_after = datetime.strptime(cert['notAfter'], '%b %d %H:%M:%S %Y %Z')
            not_before = datetime.strptime(cert['notBefore'], '%b %d %H:%M:%S %Y %Z')
            
            days_until_expiry = (not_after - datetime.now()).days
            
            return {
                'endpoint': endpoint,
                'valid': days_until_expiry > 0,
                'days_until_expiry': days_until_expiry,
                'not_after': not_after.isoformat(),
                'not_before': not_before.isoformat(),
                'subject': dict(x[0] for x in cert.get('subject', [])),
                'issuer': dict(x[0] for x in cert.get('issuer', []))
            }
        except Exception as e:
            return {
                'endpoint': endpoint,
                'valid': False,
                'error': str(e)
            }
            
    def _extract_listening_ports(self) -> List[int]:
        """从配置文件提取监听端口"""
        ports = []
        try:
            if self.config_file.exists():
                with open(self.config_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                    
                import re
                site_addresses = re.findall(r'^([^\s{]+)\s*{', content, re.MULTILINE)

                for address in site_addresses:
                    address = address.strip()
                    if not address:
                        continue

                    if address.startswith(':'):
                        port_part = address[1:]
                        if port_part.isdigit():
                            ports.append(int(port_part))
                        continue

                    if '://' in address:
                        parsed = urllib.parse.urlparse(address)
                        if parsed.port:
                            ports.append(parsed.port)
                        elif parsed.scheme == 'https':
                            ports.append(443)
                        else:
                            ports.append(80)
                        continue

                    host, separator, port_part = address.rpartition(':')
                    if separator and host and port_part.isdigit():
                        ports.append(int(port_part))

                if not ports:
                    is_local_config = any(token in content for token in ['localhost', '127.0.0.1', '0.0.0.0'])
                    if is_local_config:
                        ports = [80]
                    else:
                        ports = [80, 443]
        except Exception:
            ports = [80, 443]  # 默认端口
            
        return list(set(ports))  # 去重
        
    def _extract_frontend_endpoints(self) -> List[str]:
        """从配置文件提取前端端点"""
        endpoints = []
        try:
            if self.config_file.exists():
                with open(self.config_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                    
                import re
                # 提取域名配置
                domain_patterns = re.findall(r'^([^\s{]+)\s*{', content, re.MULTILINE)
                
                for domain in domain_patterns:
                    domain = domain.strip()
                    if domain.startswith(':'):
                        # :80 格式
                        endpoints.append(f'http://localhost{domain}')
                    elif domain.startswith('http://') or domain.startswith('https://'):
                        endpoints.append(domain)
                    elif ':' in domain and not domain.startswith('http'):
                        # example.com:8080 格式
                        if domain.startswith('localhost') or '127.0.0.1' in domain:
                            endpoints.append(f'http://{domain}')
                        else:
                            endpoints.append(f'https://{domain}')
                    else:
                        # 普通域名
                        if domain == 'localhost' or domain.startswith('127.') or domain.endswith('.local'):
                            endpoints.append(f'http://{domain}')
                        else:
                            endpoints.append(f'https://{domain}')
                            
        except Exception:
            endpoints = ['http://localhost']
            
        return endpoints
        
    def _extract_backend_endpoints(self) -> List[str]:
        """从配置文件提取后端端点"""
        backends = []
        try:
            if self.config_file.exists():
                with open(self.config_file, 'r', encoding='utf-8') as f:
                    content = f.read()
                    
                import re
                # 提取 reverse_proxy 配置
                proxy_patterns = re.findall(r'reverse_proxy\s+([^\s{]+)', content)
                
                for backend in proxy_patterns:
                    backends.append(backend.strip())
                    
        except Exception:
            pass
            
        return backends
        
    def _extract_https_endpoints(self) -> List[str]:
        """从配置文件提取HTTPS端点"""
        endpoints = self._extract_frontend_endpoints()
        return [ep for ep in endpoints if ep.startswith('https://')]
        
    def _get_recent_logs(self, lines: int = 50) -> List[str]:
        """获取最近的日志"""
        try:
            if self.log_file.exists():
                with open(self.log_file, 'r', encoding='utf-8') as f:
                    all_lines = f.readlines()
                    return [line.strip() for line in all_lines[-lines:]]
        except Exception:
            pass
        return []
        
    def _get_system_info(self) -> Dict:
        """获取系统信息"""
        return {
            'platform': platform.platform(),
            'python_version': sys.version,
            'caddy_path': str(self.caddy_path),
            'config_dir': str(self.config_dir),
            'uptime': self._get_uptime()
        }
        
    def _get_uptime(self) -> Optional[str]:
        """获取服务运行时间"""
        try:
            if self.pid_file.exists():
                pid_mtime = datetime.fromtimestamp(self.pid_file.stat().st_mtime)
                uptime = datetime.now() - pid_mtime
                return str(uptime).split('.')[0]  # 去掉微秒
        except Exception:
            pass
        return None
        
    def _get_server_ip(self) -> Optional[str]:
        """获取服务器公网IP地址"""
        try:
            # 尝试多个IP查询服务
            ip_services = [
                'https://ipinfo.io/ip',
                'https://api.ipify.org',
                'https://checkip.amazonaws.com',
                'https://icanhazip.com'
            ]
            
            for service in ip_services:
                try:
                    with urllib.request.urlopen(service, timeout=10) as response:
                        ip = response.read().decode().strip()
                        # 简单验证IP格式
                        if '.' in ip and len(ip.split('.')) == 4:
                            return ip
                except Exception:
                    continue
        except Exception:
            pass
        return None
        
    def _check_dns_resolution(self, domain: str) -> Optional[str]:
        """检查域名DNS解析"""
        try:
            # 移除端口号
            if ':' in domain and not domain.startswith('http'):
                domain = domain.split(':')[0]
            
            # 移除协议前缀
            if domain.startswith('http://') or domain.startswith('https://'):
                domain = urllib.parse.urlparse(domain).hostname
            
            # 跳过本地域名
            if domain in ['localhost', '127.0.0.1', '0.0.0.0'] or domain.startswith('127.'):
                return None
                
            result = subprocess.run(['nslookup', domain], 
                                  capture_output=True, text=True, timeout=10)
            
            if result.returncode == 0:
                # 提取IP地址，查找 "Non-authoritative answer:" 后面的地址
                lines = result.stdout.split('\n')
                found_answer_section = False
                
                for line in lines:
                    line = line.strip()
                    # 找到答案部分
                    if 'Non-authoritative answer:' in line:
                        found_answer_section = True
                        continue
                    
                    # 在答案部分查找地址
                    if found_answer_section and line.startswith('Address:'):
                        ip = line.split('Address:')[1].strip()
                        # 验证IP格式
                        import re
                        if re.match(r'^(\d{1,3}\.){3}\d{1,3}$', ip):
                            return ip
                    
                    # 也处理 "Name: domain" 后面紧跟 "Address: ip" 的情况
                    if line.startswith('Name:') and domain in line:
                        found_answer_section = True
                        continue
                        
                # 如果没有找到，检查是否有错误信息
                if "Can't find" in result.stdout or "No answer" in result.stdout:
                    return None
        except Exception:
            pass
        return None
        
    def _show_dns_guide(self, domain: str, server_ip: str, dns_ip: Optional[str] = None) -> None:
        """显示DNS配置指南"""
        # 检查是否为本地域名
        clean_domain = domain.split(':')[0] if ':' in domain else domain
        if clean_domain in ['localhost', '127.0.0.1', '0.0.0.0'] or clean_domain.startswith('127.'):
            return
            
        self.logger.info("\n" + "="*60)
        self.logger.info("🌐 DNS 配置检查")
        self.logger.info("="*60)
        
        self.logger.info(f"域名: {clean_domain}")
        self.logger.info(f"服务器IP: {server_ip}")
        
        if dns_ip:
            if dns_ip == server_ip:
                self.logger.info(f"DNS解析: {dns_ip} ✅ (已正确解析)")
                self.logger.info("\n🎉 DNS配置正确！SSL证书将自动获取。")
            else:
                self.logger.info(f"DNS解析: {dns_ip} ❌ (解析到错误IP)")
                self._show_dns_setup_instructions(clean_domain, server_ip)
        else:
            self.logger.info("DNS解析: 无记录 ❌")
            self._show_dns_setup_instructions(clean_domain, server_ip)
            
    def _show_dns_setup_instructions(self, domain: str, server_ip: str) -> None:
        """显示DNS设置说明"""
        self.logger.info(f"\n📋 DNS配置说明")
        self.logger.info("-" * 40)
        self.logger.info("1. 登录你的域名管理面板")
        self.logger.info("2. 添加或修改以下DNS记录:")
        self.logger.info(f"   • 记录类型: A")
        self.logger.info(f"   • 主机记录: @ (或留空)")
        self.logger.info(f"   • 记录值: {server_ip}")
        self.logger.info(f"   • TTL: 600秒 (或默认)")
        self.logger.info("\n3. 保存配置并等待DNS传播 (通常5-10分钟)")
        
        self.logger.info(f"\n🔍 验证命令:")
        self.logger.info(f"   nslookup {domain}")
        
        self.logger.info(f"\n⏳ DNS传播后的效果:")
        self.logger.info("   • 自动获取Let's Encrypt SSL证书")
        self.logger.info("   • 启用HTTPS访问")
        self.logger.info("   • 自动HTTP到HTTPS重定向")
        
        self.logger.info(f"\n✅ 配置成功后访问: https://{domain}")
        
    def _post_deploy_dns_check(self, domain: str) -> None:
        """部署后DNS配置检查"""
        try:
            # 获取服务器IP
            server_ip = self._get_server_ip()
            if not server_ip:
                self.logger.warning("无法获取服务器公网IP，跳过DNS检查")
                return
                
            # 检查DNS解析
            dns_ip = self._check_dns_resolution(domain)
            
            # 显示DNS配置指南
            self._show_dns_guide(domain, server_ip, dns_ip)
            
        except Exception as e:
            self.logger.warning(f"DNS检查失败: {e}")
        
    def monitor_logs(self, follow: bool = True, lines: int = 20) -> None:
        """实时监控日志"""
        self.logger.info(f"监控日志文件: {self.log_file}")
        
        try:
            if not self.log_file.exists():
                self.logger.warning("日志文件不存在")
                return
                
            # 显示最近的日志
            recent_logs = self._get_recent_logs(lines)
            if recent_logs:
                self.logger.info(f"=== 最近 {len(recent_logs)} 行日志 ===")
                for log_line in recent_logs:
                    print(log_line)
                    
            if follow:
                self.logger.info("=== 实时监控 (按 Ctrl+C 退出) ===")
                self._follow_log_file()
                
        except KeyboardInterrupt:
            self.logger.info("监控已停止")
        except Exception as e:
            self.logger.error(f"监控日志失败: {e}")
            
    def _follow_log_file(self) -> None:
        """跟踪日志文件变化"""
        try:
            with open(self.log_file, 'r', encoding='utf-8') as f:
                # 移动到文件末尾
                f.seek(0, 2)
                
                while True:
                    line = f.readline()
                    if line:
                        print(line.rstrip())
                    else:
                        time.sleep(0.1)
        except Exception as e:
            self.logger.error(f"日志跟踪失败: {e}")
            
    def diagnose(self) -> Dict:
        """完整诊断报告"""
        self.logger.info("开始诊断检查...")
        
        diagnosis = {
            'timestamp': datetime.now().isoformat(),
            'health_check': self.health_check(detailed=True),
            'recommendations': []
        }
        
        # 基于检查结果生成建议
        health_checks = diagnosis['health_check']['checks']
        
        if health_checks['process']['status'] != 'ok':
            diagnosis['recommendations'].append("建议检查Caddy服务是否正确启动")
            
        if health_checks['config']['status'] != 'ok':
            diagnosis['recommendations'].append("建议检查配置文件语法和有效性")
            
        if health_checks['backend']['status'] == 'warning':
            diagnosis['recommendations'].append("建议检查后端服务是否正常运行")
            
        if health_checks['ssl']['status'] == 'warning':
            diagnosis['recommendations'].append("建议检查SSL证书状态和有效期")
            
        return diagnosis

def build_parser() -> Tuple[argparse.ArgumentParser, argparse.ArgumentParser]:
    """构建命令行解析器"""
    parser = argparse.ArgumentParser(
        description="Caddy部署脚本 - 完整的Caddy服务管理工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 部署服务到localhost:80，代理到后端3000端口
  python caddy_deployer.py deploy --domain localhost --port 3000
  
  # 部署服务到自定义域名，启用HTTPS
  python caddy_deployer.py deploy --domain example.com --port 8080 --ssl
  
  # 使用自定义配置文件部署
  python caddy_deployer.py deploy --config custom_caddyfile.txt
  
  # 停止服务
  python caddy_deployer.py undeploy
  
  # 检查服务状态
  python caddy_deployer.py status
  
  # 健康检查
  python caddy_deployer.py health-check
  
  # 详细健康检查
  python caddy_deployer.py health-check --detailed
  
  # 查看日志
  python caddy_deployer.py logs
  
  # 实时监控日志
  python caddy_deployer.py logs --follow
  
  # 完整诊断
  python caddy_deployer.py diagnose
        """
    )
    
    subparsers = parser.add_subparsers(dest='command', help='可用命令')
    
    # deploy命令
    deploy_parser = subparsers.add_parser('deploy', help='部署Caddy服务')
    deploy_parser.add_argument('--domain', '-d', default='localhost:80',
                              help='服务域名或地址 (默认: localhost:80)')
    deploy_parser.add_argument('--port', '-p', type=int,
                              help='后端服务端口；未使用 --config 时必填')
    deploy_parser.add_argument('--backend-host', default='127.0.0.1',
                              help='后端服务地址 (默认: 127.0.0.1)')
    deploy_parser.add_argument('--ssl', action='store_true',
                              help='启用SSL/HTTPS')
    deploy_parser.add_argument('--config', '-c',
                              help='自定义配置文件路径')
    deploy_parser.add_argument('--install', action='store_true',
                              help='自动安装Caddy (如果不存在)')
    deploy_parser.add_argument('--force-install', action='store_true',
                              help='强制重新安装Caddy')
    
    # undeploy命令
    undeploy_parser = subparsers.add_parser('undeploy', help='停止Caddy服务')
    
    # status命令
    status_parser = subparsers.add_parser('status', help='检查服务状态')
    
    # health-check命令
    health_parser = subparsers.add_parser('health-check', help='健康检查')
    health_parser.add_argument('--detailed', '-v', action='store_true',
                              help='显示详细信息')
    health_parser.add_argument('--json', action='store_true',
                              help='JSON格式输出')
    
    # logs命令
    logs_parser = subparsers.add_parser('logs', help='查看和监控日志')
    logs_parser.add_argument('--follow', '-f', action='store_true',
                            help='实时跟踪日志')
    logs_parser.add_argument('--lines', '-n', type=int, default=20,
                            help='显示行数 (默认: 20)')
    
    # diagnose命令
    diagnose_parser = subparsers.add_parser('diagnose', help='完整诊断报告')
    diagnose_parser.add_argument('--json', action='store_true',
                                help='JSON格式输出')
    
    # install命令
    install_parser = subparsers.add_parser('install', help='安装Caddy')
    install_parser.add_argument('--force', action='store_true',
                               help='强制重新安装')

    return parser, deploy_parser


def validate_deploy_args(args: argparse.Namespace, deploy_parser: argparse.ArgumentParser) -> None:
    """校验deploy子命令参数"""
    if args.command != 'deploy':
        return

    if not args.config and args.port is None:
        deploy_parser.error("--port is required unless --config is provided")


def main():
    """主函数"""
    parser, deploy_parser = build_parser()
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return 1

    validate_deploy_args(args, deploy_parser)
    
    # 创建部署器实例
    deployer = CaddyDeployer()
    
    try:
        if args.command == 'deploy':
            # 检查依赖
            if not deployer.check_dependencies():
                return 1
            
            # 安装Caddy (如果需要)
            if args.force_install or (args.install and not deployer.caddy_path.exists()):
                if not deployer.install_caddy(force=args.force_install):
                    return 1
            elif not deployer.caddy_path.exists():
                deployer.logger.error(f"Caddy未找到: {deployer.caddy_path}")
                deployer.logger.info("请使用 --install 参数自动安装，或手动安装Caddy")
                return 1
            
            # 生成配置
            custom_config = None
            if args.config:
                try:
                    with open(args.config, 'r', encoding='utf-8') as f:
                        custom_config = f.read()
                except Exception as e:
                    deployer.logger.error(f"读取配置文件失败: {e}")
                    return 1
            
            if not deployer.generate_config(
                domain=args.domain,
                backend_port=args.port,
                backend_host=args.backend_host,
                enable_ssl=args.ssl,
                custom_config=custom_config
            ):
                return 1
            
            # 验证配置
            if not deployer.validate_config():
                return 1
            
            # 部署服务
            if deployer.deploy():
                deployer.logger.info("部署成功！")
                deployer.logger.info(f"访问地址: http{'s' if args.ssl else ''}://{args.domain}")
                
                # 进行DNS配置检查
                deployer._post_deploy_dns_check(args.domain)
                
                return 0
            else:
                return 1
                
        elif args.command == 'undeploy':
            if deployer.undeploy():
                deployer.logger.info("服务停止成功！")
                return 0
            else:
                return 1
                
        elif args.command == 'status':
            status = deployer.status()
            deployer.logger.info("=== Caddy服务状态 ===")
            deployer.logger.info(f"运行状态: {'运行中' if status['running'] else '已停止'}")
            deployer.logger.info(f"Caddy路径: {status['caddy_path']}")
            deployer.logger.info(f"配置文件: {status['config_file']}")
            deployer.logger.info(f"日志文件: {status['log_file']}")
            if 'pid' in status:
                deployer.logger.info(f"进程ID: {status['pid']}")
            return 0
            
        elif args.command == 'health-check':
            health_status = deployer.health_check(detailed=args.detailed)
            
            if args.json:
                print(json.dumps(health_status, indent=2, ensure_ascii=False))
            else:
                deployer.logger.info("=== 健康检查报告 ===")
                deployer.logger.info(f"检查时间: {health_status['timestamp']}")
                deployer.logger.info(f"整体状态: {health_status['overall_status']}")
                
                for check_name, check_result in health_status['checks'].items():
                    status_emoji = {
                        'ok': '✅',
                        'warning': '⚠️',
                        'error': '❌',
                        'info': 'ℹ️'
                    }.get(check_result['status'], '❓')
                    
                    deployer.logger.info(f"{status_emoji} {check_name}: {check_result['message']}")
                    
                    if args.detailed and 'tests' in check_result:
                        for test in check_result['tests']:
                            test_status = '✅' if test.get('success', False) else '❌'
                            deployer.logger.info(f"  {test_status} {test.get('endpoint', test.get('backend', 'N/A'))}: {test.get('message', 'N/A')}")
                            
            return 0 if health_status['overall_status'] == 'healthy' else 1
            
        elif args.command == 'logs':
            deployer.monitor_logs(follow=args.follow, lines=args.lines)
            return 0
            
        elif args.command == 'diagnose':
            diagnosis = deployer.diagnose()
            
            if args.json:
                print(json.dumps(diagnosis, indent=2, ensure_ascii=False))
            else:
                deployer.logger.info("=== 完整诊断报告 ===")
                deployer.logger.info(f"诊断时间: {diagnosis['timestamp']}")
                
                health = diagnosis['health_check']
                deployer.logger.info(f"整体健康状态: {health['overall_status']}")
                
                deployer.logger.info("\n📋 检查详情:")
                for check_name, check_result in health['checks'].items():
                    status_emoji = {
                        'ok': '✅',
                        'warning': '⚠️', 
                        'error': '❌',
                        'info': 'ℹ️'
                    }.get(check_result['status'], '❓')
                    
                    deployer.logger.info(f"  {status_emoji} {check_name}: {check_result['message']}")
                    
                if diagnosis['recommendations']:
                    deployer.logger.info("\n💡 建议:")
                    for i, rec in enumerate(diagnosis['recommendations'], 1):
                        deployer.logger.info(f"  {i}. {rec}")
                        
                if 'system_info' in health:
                    deployer.logger.info("\n🖥️  系统信息:")
                    sys_info = health['system_info']
                    deployer.logger.info(f"  平台: {sys_info['platform']}")
                    deployer.logger.info(f"  Caddy路径: {sys_info['caddy_path']}")
                    if sys_info.get('uptime'):
                        deployer.logger.info(f"  运行时间: {sys_info['uptime']}")
                        
            return 0 if health['overall_status'] == 'healthy' else 1
            
        elif args.command == 'install':
            if deployer.install_caddy(force=args.force):
                deployer.logger.info("Caddy安装成功！")
                return 0
            else:
                return 1
                
    except KeyboardInterrupt:
        deployer.logger.info("操作被用户中断")
        return 1
    except Exception as e:
        deployer.logger.error(f"未预期的错误: {e}")
        return 1


if __name__ == '__main__':
    sys.exit(main())
