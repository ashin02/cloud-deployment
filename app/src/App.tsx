import { useState } from 'react'

export default function App() {
  const [count, setCount] = useState(0)

  return (
    <main>
      <p className="eyebrow">Deployment lab · M1</p>
      <h1>A small app. A place to start.</h1>
      <p>A simple counter for practicing how software gets shipped.</p>
      <output aria-label="Counter" aria-live="polite">{count}</output>
      <div className="actions">
        <button onClick={() => setCount((value) => value + 1)}>Increment</button>
        <button className="secondary" onClick={() => setCount(0)}>Reset</button>
      </div>
      <p className="note">The count resets when you refresh.</p>
    </main>
  )
}
