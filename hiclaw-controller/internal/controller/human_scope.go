package controller

import (
	"context"

	v1beta1 "github.com/hiclaw/hiclaw-controller/api/v1beta1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// humanScope carries cross-phase state for a single Reconcile pass.
// Fields set by earlier phases are consumed by later phases; keeping them
// in one place avoids threading extra return values through every phase
// function and mirrors the scope pattern used by managerScope.
type humanScope struct {
	human     *v1beta1.Human
	patchBase client.Patch

	// userToken is the Human's own Matrix access token for this reconcile
	// pass, obtained either from EnsureHumanUser (first-time) or
	// LoginAsHuman (steady-state). Empty when login failed (e.g. the user
	// changed their password in Element); rooms phase then degrades to
	// admin-only invite without /join.
	userToken string
}

// computeHumanPhase derives the observable Phase from reconcile outcome.
//
// Behavior matches the pre-refactor controller:
//   - success → "Active" once MatrixUserID is set; otherwise "Pending"
//   - error → "Failed" when no user has been provisioned yet
//     (reconcile is stuck before it can report a real state), or the
//     previous Phase otherwise (transient errors keep us in "Active").
func computeHumanPhase(h *v1beta1.Human, reconcileErr error) string {
	if reconcileErr != nil {
		if h.Status.MatrixUserID == "" {
			return "Failed"
		}
		if h.Status.Phase == "" {
			return "Pending"
		}
		return h.Status.Phase
	}
	if h.Status.MatrixUserID == "" {
		return "Pending"
	}
	return "Active"
}

// buildDesiredHumanRooms resolves Spec.AccessibleWorkers / AccessibleTeams
// into the set of Matrix room IDs the human should currently be a member
// of. Workers/Teams that don't exist or haven't finished provisioning
// (empty Status.RoomID / TeamRoomID) are simply skipped — they'll be
// picked up on a later reconcile once their rooms materialize.
//
// Returned as a set (map-to-empty-struct) rather than a slice because
// the reconciler does membership comparisons against the observed
// Status.Rooms set.
func buildDesiredHumanRooms(ctx context.Context, c client.Client, h *v1beta1.Human) map[string]struct{} {
	desired := make(map[string]struct{})
	for _, workerName := range h.Spec.AccessibleWorkers {
		var worker v1beta1.Worker
		if err := c.Get(ctx, client.ObjectKey{Name: workerName, Namespace: h.Namespace}, &worker); err != nil {
			continue
		}
		if worker.Status.RoomID != "" {
			desired[worker.Status.RoomID] = struct{}{}
		}
	}
	for _, teamName := range h.Spec.AccessibleTeams {
		var team v1beta1.Team
		if err := c.Get(ctx, client.ObjectKey{Name: teamName, Namespace: h.Namespace}, &team); err != nil {
			continue
		}
		if team.Status.TeamRoomID != "" {
			desired[team.Status.TeamRoomID] = struct{}{}
		}
	}
	return desired
}

// isRoomFromAccessibleWorker checks if roomID belongs to a worker still in accessibleWorkers.
// Returns (true, nil) if worker is in accessibleWorkers AND roomID matches.
// Returns (true, nil) if worker is in accessibleWorkers AND RoomID is empty (worker not provisioned yet).
// Returns (false, err) if API fails - caller should skip kick for safety.
// Returns (false, nil) if roomID doesn't match any accessible worker (safe to kick).
func isRoomFromAccessibleWorker(ctx context.Context, c client.Client, ns, roomID string, accessibleWorkers []string) (bool, error) {
	for _, workerName := range accessibleWorkers {
		var worker v1beta1.Worker
		if err := c.Get(ctx, client.ObjectKey{Name: workerName, Namespace: ns}, &worker); err != nil {
			return false, err
		}
		// Exact match - room belongs to this worker
		if worker.Status.RoomID == roomID {
			return true, nil
		}
		// Worker exists in accessibleWorkers but hasn't been provisioned yet
		// Don't kick - room might be the worker's future room
		if worker.Status.RoomID == "" {
			return true, nil
		}
	}
	return false, nil
}
