<script>
  import { toast } from '../lib/store.js';
</script>

{#if $toast.show}
  <div class="fixed top-4 right-4 z-50 px-4 py-3 rounded-lg shadow-lg text-white text-sm transition-all"
    class:bg-green-500={$toast.type === 'success'}
    class:bg-red-500={$toast.type === 'error'}
    class:bg-blue-500={$toast.type === 'info'}
  >
    {$toast.message}
  </div>
{/if}
