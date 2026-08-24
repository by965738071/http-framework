<script>
  import { onMount } from 'svelte';
  import { api } from '../lib/api.js';

  let stats = { total_users: 0, admins: 0, editors: 0, viewers: 0, total_logs: 0 };
  let deviceStats = { total: 0, online: 0, offline: 0, maintenance: 0 };
  let loading = true;

  onMount(async () => {
    try {
      const [userStats, devices] = await Promise.all([
        api.getUsers ? Promise.resolve({ total_users: 0, admins: 0 }) : fetch('/admin/dashboard', { credentials: 'same-origin' }).then(r => r.json()),
        api.getDevices().catch(() => ({ total: 0, devices: [] }))
      ]);
      
      if (userStats) stats = { ...stats, ...userStats };
      
      if (devices.devices) {
        deviceStats.total = devices.total;
        deviceStats.online = devices.devices.filter(d => d.status === 'online').length;
        deviceStats.offline = devices.devices.filter(d => d.status === 'offline').length;
        deviceStats.maintenance = devices.devices.filter(d => d.status === 'maintenance').length;
      }
    } catch {}
    loading = false;
  });
</script>

<div class="max-w-6xl mx-auto">
  <h1 class="text-2xl font-bold text-gray-900 mb-6">仪表盘</h1>
  
  {#if loading}
    <div class="text-center py-12 text-gray-500">加载中...</div>
  {:else}
    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
      <div class="bg-white rounded-xl shadow-sm p-6 border border-gray-100">
        <div class="text-sm text-gray-500">用户总数</div>
        <div class="text-3xl font-bold text-blue-600 mt-1">{stats.total_users}</div>
      </div>
      <div class="bg-white rounded-xl shadow-sm p-6 border border-gray-100">
        <div class="text-sm text-gray-500">设备总数</div>
        <div class="text-3xl font-bold text-green-600 mt-1">{deviceStats.total}</div>
      </div>
      <div class="bg-white rounded-xl shadow-sm p-6 border border-gray-100">
        <div class="text-sm text-gray-500">在线设备</div>
        <div class="text-3xl font-bold text-emerald-600 mt-1">{deviceStats.online}</div>
      </div>
      <div class="bg-white rounded-xl shadow-sm p-6 border border-gray-100">
        <div class="text-sm text-gray-500">离线设备</div>
        <div class="text-3xl font-bold text-red-600 mt-1">{deviceStats.offline}</div>
      </div>
    </div>
    
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
      <div class="bg-white rounded-xl shadow-sm p-6 border border-gray-100">
        <h3 class="font-semibold text-gray-900 mb-4">用户角色分布</h3>
        <div class="space-y-3">
          <div class="flex justify-between"><span class="text-gray-600">管理员</span><span class="font-medium">{stats.admins}</span></div>
          <div class="flex justify-between"><span class="text-gray-600">编辑者</span><span class="font-medium">{stats.editors}</span></div>
          <div class="flex justify-between"><span class="text-gray-600">查看者</span><span class="font-medium">{stats.viewers}</span></div>
        </div>
      </div>
      <div class="bg-white rounded-xl shadow-sm p-6 border border-gray-100">
        <h3 class="font-semibold text-gray-900 mb-4">设备状态</h3>
        <div class="space-y-3">
          <div class="flex justify-between"><span class="text-gray-600">在线</span><span class="font-medium text-green-600">{deviceStats.online}</span></div>
          <div class="flex justify-between"><span class="text-gray-600">离线</span><span class="font-medium text-red-600">{deviceStats.offline}</span></div>
          <div class="flex justify-between"><span class="text-gray-600">维护中</span><span class="font-medium text-yellow-600">{deviceStats.maintenance}</span></div>
        </div>
      </div>
    </div>
  {/if}
</div>
