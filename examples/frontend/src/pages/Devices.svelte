<script>
  import { onMount } from 'svelte';
  import { api } from '../lib/api.js';
  import { showToast } from '../lib/store.js';
  import Modal from '../components/Modal.svelte';

  let devices = [];
  let loading = true;
  let showModal = false;
  let editingDevice = null;
  let filterType = '';
  let filterStatus = '';
  let form = { name: '', type: 'sensor', status: 'offline', serial_number: '', location: '' };

  const deviceTypes = [
    { value: 'sensor', label: '传感器' },
    { value: 'actuator', label: '执行器' },
    { value: 'gateway', label: '网关' },
    { value: 'controller', label: '控制器' },
  ];

  const deviceStatuses = [
    { value: 'online', label: '在线' },
    { value: 'offline', label: '离线' },
    { value: 'maintenance', label: '维护中' },
    { value: 'error', label: '故障' },
  ];

  onMount(loadDevices);

  async function loadDevices() {
    loading = true;
    try {
      const params = {};
      if (filterType) params.type = filterType;
      if (filterStatus) params.status = filterStatus;
      const data = await api.getDevices(params);
      devices = data.devices || [];
    } catch (e) {
      showToast('加载设备失败: ' + e.message, 'error');
    }
    loading = false;
  }

  function showAdd() {
    editingDevice = null;
    form = { name: '', type: 'sensor', status: 'offline', serial_number: '', location: '' };
    showModal = true;
  }

  function showEdit(device) {
    editingDevice = device;
    form = { name: device.name, type: device.type, status: device.status, serial_number: device.serial_number, location: device.location };
    showModal = true;
  }

  async function handleSave() {
    try {
      if (editingDevice) {
        await api.updateDevice(editingDevice.id, form);
        showToast('设备更新成功', 'success');
      } else {
        await api.createDevice(form);
        showToast('设备创建成功', 'success');
      }
      showModal = false;
      loadDevices();
    } catch (e) {
      showToast(e.message, 'error');
    }
  }

  async function handleDelete(device) {
    if (!confirm(`确定删除设备 ${device.name}？`)) return;
    try {
      await api.deleteDevice(device.id);
      showToast('设备已删除', 'success');
      loadDevices();
    } catch (e) {
      showToast(e.message, 'error');
    }
  }

  function getStatusColor(status) {
    return status === 'online' ? 'bg-green-100 text-green-700' :
           status === 'offline' ? 'bg-red-100 text-red-700' :
           status === 'maintenance' ? 'bg-yellow-100 text-yellow-700' :
           'bg-gray-100 text-gray-700';
  }

  function getTypeLabel(type) {
    return deviceTypes.find(t => t.value === type)?.label || type;
  }

  function getStatusLabel(status) {
    return deviceStatuses.find(s => s.value === status)?.label || status;
  }

  $: if (filterType !== undefined || filterStatus !== undefined) loadDevices();
</script>

<div class="max-w-6xl mx-auto">
  <div class="flex justify-between items-center mb-6">
    <h1 class="text-2xl font-bold text-gray-900">设备管理</h1>
    <button class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg" on:click={showAdd}>
      添加设备
    </button>
  </div>

  <div class="flex gap-4 mb-6">
    <select bind:value={filterType} class="px-3 py-2 border border-gray-300 rounded-lg text-sm">
      <option value="">所有类型</option>
      {#each deviceTypes as t}
        <option value={t.value}>{t.label}</option>
      {/each}
    </select>
    <select bind:value={filterStatus} class="px-3 py-2 border border-gray-300 rounded-lg text-sm">
      <option value="">所有状态</option>
      {#each deviceStatuses as s}
        <option value={s.value}>{s.label}</option>
      {/each}
    </select>
  </div>

  {#if loading}
    <div class="text-center py-12 text-gray-500">加载中...</div>
  {:else}
    <div class="bg-white rounded-xl shadow-sm border border-gray-100 overflow-hidden">
      <table class="w-full">
        <thead class="bg-gray-50">
          <tr>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">ID</th>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">名称</th>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">类型</th>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">状态</th>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">序列号</th>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">位置</th>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">操作</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-200">
          {#each devices as device}
            <tr class="hover:bg-gray-50">
              <td class="px-6 py-4 text-sm text-gray-900">{device.id}</td>
              <td class="px-6 py-4 text-sm text-gray-900 font-medium">{device.name}</td>
              <td class="px-6 py-4 text-sm text-gray-500">{getTypeLabel(device.type)}</td>
              <td class="px-6 py-4">
                <span class="px-2 py-1 text-xs rounded-full {getStatusColor(device.status)}">
                  {getStatusLabel(device.status)}
                </span>
              </td>
              <td class="px-6 py-4 text-sm text-gray-500 font-mono">{device.serial_number}</td>
              <td class="px-6 py-4 text-sm text-gray-500">{device.location}</td>
              <td class="px-6 py-4 text-sm space-x-2">
                <button class="text-blue-600 hover:underline" on:click={() => showEdit(device)}>编辑</button>
                <button class="text-red-600 hover:underline" on:click={() => handleDelete(device)}>删除</button>
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>

<Modal show={showModal} title={editingDevice ? '编辑设备' : '添加设备'} on:close={() => showModal = false}>
  <form on:submit|preventDefault={handleSave} class="space-y-4">
    <div>
      <label class="block text-sm font-medium text-gray-700 mb-1">设备名称</label>
      <input type="text" bind:value={form.name} required
        class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500" />
    </div>
    <div>
      <label class="block text-sm font-medium text-gray-700 mb-1">设备类型</label>
      <select bind:value={form.type} class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500">
        {#each deviceTypes as t}
          <option value={t.value}>{t.label}</option>
        {/each}
      </select>
    </div>
    <div>
      <label class="block text-sm font-medium text-gray-700 mb-1">状态</label>
      <select bind:value={form.status} class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500">
        {#each deviceStatuses as s}
          <option value={s.value}>{s.label}</option>
        {/each}
      </select>
    </div>
    <div>
      <label class="block text-sm font-medium text-gray-700 mb-1">序列号</label>
      <input type="text" bind:value={form.serial_number} required
        class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500" />
    </div>
    <div>
      <label class="block text-sm font-medium text-gray-700 mb-1">位置</label>
      <input type="text" bind:value={form.location}
        class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500" />
    </div>
  </form>
  <div slot="actions">
    <button class="px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded-lg" on:click={() => showModal = false}>取消</button>
    <button class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg" on:click={handleSave}>保存</button>
  </div>
</Modal>
