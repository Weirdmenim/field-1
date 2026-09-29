import React from 'react'
import ReactDOM from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import App from './App'
import AuthGate from './components/auth/AuthGate'
import { AuthProvider } from './lib/auth'
import './index.css'
import { registerOfflineShell } from './lib/pwa'

const queryClient = new QueryClient()

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <AuthGate>
          <App />
        </AuthGate>
      </AuthProvider>
    </QueryClientProvider>
  </React.StrictMode>,
)

void registerOfflineShell()
