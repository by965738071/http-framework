<script>
  import { currentUser, currentPage, isAuthenticated, navigate, showToast } from '../lib/store.js';
  import { api } from '../lib/api.js';

  async function logout() {
    try { await api.logout(); } catch {}
    currentUser.set(null);
    isAuthenticated.set(false);
    navigate('login');
    showToast('已退出登录', 'info');
  }

  const navItems = [
    { id: 'dashboard', label: '仪表盘', icon: '📊' },
    { id: 'users', label: '用户管理', icon: '👥' },
    { id: 'devices', label: '设备管理', icon: '🔧' },
  ];
</script>

<aside class="w-64 bg-gray-900 text-white flex flex-col">
  <div class="p-4 border-b border-gray-700">
    <h2 class="text-xl font-bold">设备管理系统</h2>
    {#if $currentUser}
      <p class="text-sm text-gray-400 mt-1">{$currentUser.username} ({$currentUser.role})</p>
    {/if}
  </div>
  <nav class="flex-1 p-4 space-y-2">
    {#each navItems as item}
      <button
        class="w-full flex items-center gap-3 px-3 py-2 rounded-lg transition-colors {$currentPage === item.id ? 'bg-blue-600 text-white' : 'text-gray-300 hover:bg-gray-800'}"
        on:click={() => navigate(item.id)}
      >
        <span>{item.icon}</span>
        <span>{item.label}</span>
      </button>
    {/each}
  </nav>
  <div class="p-4 border-t border-gray-700">
    <button class="w-full px-3 py-2 bg-red-600 hover:bg-red-700 rounded-lg text-sm" on:click={logout}>
      退出登录
    </button>
  </div>
</aside>
