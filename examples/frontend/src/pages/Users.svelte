<script>
  import { onMount } from 'svelte';
  import { api } from '../lib/api.js';
  import { showToast } from '../lib/store.js';
  import Modal from '../components/Modal.svelte';

  let users = [];
  let loading = true;
  let showModal = false;
  let editingUser = null;
  let form = { username: '', display_name: '', email: '', password: '' };

  onMount(loadUsers);

  async function loadUsers() {
    loading = true;
    try {
      const data = await api.getUsers();
      users = data.items || [];
    } catch (e) {
      showToast('加载用户失败: ' + e.message, 'error');
    }
    loading = false;
  }

  function showAdd() {
    editingUser = null;
    form = { username: '', display_name: '', email: '', password: '' };
    showModal = true;
  }

  function showEdit(user) {
    editingUser = user;
    form = { username: user.username, display_name: user.display_name, email: user.email, password: '' };
    showModal = true;
  }

  function roleLabels(user) {
    return (user.roles || []).map(r => r.name).join(', ') || '-';
  }

  async function handleSave() {
    try {
      if (editingUser) {
        await api.updateUser(editingUser.id, { display_name: form.display_name, email: form.email });
        showToast('用户更新成功', 'success');
      } else {
        await api.createUser({ username: form.username, password: form.password, display_name: form.display_name, email: form.email, org_id: 0 });
        showToast('用户创建成功', 'success');
      }
      showModal = false;
      loadUsers();
    } catch (e) {
      showToast(e.message, 'error');
    }
  }

  async function handleDelete(user) {
    if (!confirm(`确定删除用户 ${user.username}？`)) return;
    try {
      await api.deleteUser(user.id);
      showToast('用户已删除', 'success');
      loadUsers();
    } catch (e) {
      showToast(e.message, 'error');
    }
  }
</script>

<div class="max-w-6xl mx-auto">
  <div class="flex justify-between items-center mb-6">
    <h1 class="text-2xl font-bold text-gray-900">用户管理</h1>
    <button class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg" on:click={showAdd}>
      添加用户
    </button>
  </div>

  {#if loading}
    <div class="text-center py-12 text-gray-500">加载中...</div>
  {:else}
    <div class="bg-white rounded-xl shadow-sm border border-gray-100 overflow-hidden">
      <table class="w-full">
        <thead class="bg-gray-50">
          <tr>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">ID</th>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">用户名</th>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">邮箱</th>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">角色</th>
            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">操作</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-200">
          {#each users as user}
            <tr class="hover:bg-gray-50">
              <td class="px-6 py-4 text-sm text-gray-900">{user.id}</td>
              <td class="px-6 py-4 text-sm text-gray-900">{user.username}</td>
              <td class="px-6 py-4 text-sm text-gray-500">{user.email}</td>
              <td class="px-6 py-4">
                <span class="px-2 py-1 text-xs rounded-full bg-gray-100 text-gray-700">
                  {roleLabels(user)}
                </span>
              </td>
              <td class="px-6 py-4 text-sm space-x-2">
                <button class="text-blue-600 hover:underline" on:click={() => showEdit(user)}>编辑</button>
                <button class="text-red-600 hover:underline" on:click={() => handleDelete(user)}>删除</button>
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>

<Modal show={showModal} title={editingUser ? '编辑用户' : '添加用户'} on:close={() => showModal = false}>
  <form on:submit|preventDefault={handleSave} class="space-y-4">
    <div>
      <label class="block text-sm font-medium text-gray-700 mb-1">用户名</label>
      <input type="text" bind:value={form.username} required
        class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500" />
    </div>
    <div>
      <label class="block text-sm font-medium text-gray-700 mb-1">姓名</label>
      <input type="text" bind:value={form.display_name} required
        class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500" />
    </div>
    <div>
      <label class="block text-sm font-medium text-gray-700 mb-1">邮箱</label>
      <input type="email" bind:value={form.email} required
        class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500" />
    </div>
    <div>
      <label class="block text-sm font-medium text-gray-700 mb-1">密码{editingUser ? '（更新不修改密码）' : ''}</label>
      <input type="password" bind:value={form.password}
        class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500" />
    </div>
  </form>
  <div slot="actions">
    <button class="px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded-lg" on:click={() => showModal = false}>取消</button>
    <button class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg" on:click={handleSave}>保存</button>
  </div>
</Modal>
