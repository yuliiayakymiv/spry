import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { api } from '@/lib/api'

export const meetingsKey = ['meetings'] as const
export const participantsKey = ['participants'] as const

export function useMeetings() {
  return useQuery({ queryKey: meetingsKey, queryFn: api.listMeetings })
}

export function useParticipants() {
  return useQuery({ queryKey: participantsKey, queryFn: api.listParticipants })
}

export function useCreateMeeting() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: api.createMeeting,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: meetingsKey }),
  })
}

export function useUpdateMeeting() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: api.updateMeeting,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: meetingsKey }),
  })
}

export function useSaveAgenda() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: api.saveAgenda,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: meetingsKey }),
  })
}

export function useDeleteMeeting() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: api.deleteMeeting,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: meetingsKey }),
  })
}

export function useCreateParticipant() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: api.createParticipant,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: participantsKey }),
  })
}
