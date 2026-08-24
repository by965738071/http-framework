<script>
  import { navigate, showToast, currentUser, isAuthenticated } from '../lib/store.js';
  import { api } from '../lib/api.js';

  let username = '';
  let password = '';
  let error = '';
  let loading = false;

  async function handleLogin() {
    error = '';
    loading = true;
    try {
      const data = await api.login(username, password);
      currentUser.set({ username: data.username, role: data.role });
      isAuthenticated.set(true);
      showToast('登录成功', 'success');
      navigate('dashboard');
    } catch (e) {
      error = e.message || '登录失败';
    } finally {
      loading = false;
    }
  }
</script>

<div class="min-h-screen flex items-center justify-center bg-gradient-to-br from-blue-50 to-indigo-100">
  <div class="bg-white rounded-2xl shadow-xl p-8 w-full max-w-md">
    <div class="text-center mb-8">
      <h1 class="text-3xl font-bold text-gray-900">设备管理系统</h1>
      <p class="text-gray-500 mt-2">请登录以继续</p>
    </div>
    
    {#if error}
      <div class="mb-4 p-3 bg-red-50 border border-red-200 text-red-700 rounded-lg text-sm">{error}</div>
    {/if}
    
    <form on:submit|preventDefault={handleLogin} class="space-y-4">
      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">用户名</label>
        <input type="text" bind:value={username} required
          class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent" />
      </div>
      <div>
        <label class="block text-sm font-medium text-gray-700 mb-1">密码</label>
        <input type="password" bind:value={password} required
          class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent" />
      </div>
      <button type="submit" disabled={loading}
        class="w-full py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-medium disabled:opacity-50">
        {loading ? '登录中...' : '登录'}
      </button>
    </form>
    
    <p class="text-center mt-4 text-sm text-gray-500">
      没有账号？<button class="text-blue-600 hover:underline" on:click={() => navigate('register')}>注册</button>
    </p>
  </div>
</div>
