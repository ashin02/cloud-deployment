import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import App from './App'

describe('Counter', () => {
  it('starts at zero', () => {
    render(<App />)
    expect(screen.getByRole('status', { name: 'Counter' })).toHaveTextContent(/^0$/)
  })

  it('increments on each click and resets to zero', async () => {
    const user = userEvent.setup()
    render(<App />)
    const counter = screen.getByRole('status', { name: 'Counter' })
    const increment = screen.getByRole('button', { name: 'Increment' })
    await user.click(increment)
    expect(counter).toHaveTextContent(/^1$/)
    await user.click(increment)
    expect(counter).toHaveTextContent(/^2$/)
    await user.click(screen.getByRole('button', { name: 'Reset' }))
    expect(counter).toHaveTextContent(/^0$/)
    await user.click(increment)
    expect(counter).toHaveTextContent(/^1$/)
  })

  it('supports keyboard controls and resetting an already-zero counter', async () => {
    const user = userEvent.setup()
    render(<App />)
    await user.click(screen.getByRole('button', { name: 'Reset' }))
    expect(screen.getByRole('status', { name: 'Counter' })).toHaveTextContent(/^0$/)
    await user.tab({ shift: true })
    expect(screen.getByRole('button', { name: 'Increment' })).toHaveFocus()
    await user.keyboard('{Enter}')
    expect(screen.getByRole('status', { name: 'Counter' })).toHaveTextContent(/^1$/)
  })
})
