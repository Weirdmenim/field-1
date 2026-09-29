import { createClient } from "@supabase/supabase-js"
import fs from "fs"

const supabaseUrl = process.env.VITE_SUPABASE_URL || "http://127.0.0.1:54321"
const supabaseKey = process.env.VITE_SUPABASE_ANON_KEY || "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRla3ZsZXRudWx6cmxid2Z6cWRlIiwicm9sZSI6ImFub24iLCJpYXQiOjE2OTE3NjQ5MjQsImV4cCI6MTk5NTMwMDkyNH0.abcdef1234567890"

const supabase = createClient(supabaseUrl, supabaseKey)

async function run() {
  const { data: auth, error: authErr } = await supabase.auth.signInWithPassword({
    email: 'phase10-runtime@example.test',
    password: 'Phase10!Runtime123'
  })
  if (authErr) {
    console.error("Auth error:", authErr)
    return
  }
  console.log("Logged in:", auth.user.id)
  
  const { data: work, error } = await supabase.rpc("list_my_warehouse_work", { p_location_id: "33333333-3333-3333-3333-333333333331" })
  console.log("Work 3333:", JSON.stringify(work, null, 2), error)
  
  const { data: work2, error: error2 } = await supabase.rpc("list_my_warehouse_work", { p_location_id: "1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a11" })
  console.log("Work 1a1a:", JSON.stringify(work2, null, 2), error2)
}

run()
